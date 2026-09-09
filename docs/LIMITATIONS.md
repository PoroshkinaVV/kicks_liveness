# Limitations

The predicate is computed over Bunny objects held in the worker's own memory.
That is the whole point — it keeps the health decision independent of a broker
round trip — but it has a boundary: the predicate is exactly as truthful as
Bunny's own bookkeeping. The broker is never asked for its opinion.

The first three sections below point in the same direction: an alert on
consumers, which looks at the broker from **the outside**, is part of the design
rather than a suggestion, because it catches precisely what an in-memory
predicate cannot see. The sections after them are boundaries of another kind:
what the probe does not survive, and what it does not set out to answer.

## Consumer bookkeeping is updated on the worker's thread pool

When the broker cancels a consumer — a `consumer_timeout` expiring, for
instance — it sends `basic.cancel`, and Bunny removes the consumer from its
registry. But it does that inside `@work_pool.submit`, i.e. on the same thread
pool that processes messages (`threads: 10` by default). Until a thread is free,
`any_consumers?` still answers "yes".

In practice: if **every** thread of a worker is occupied by a stuck job, the
probe stays green even though the pod is no longer consuming anything. One stuck
job out of ten does not produce this effect.

This gap cannot be closed from inside the process. It is the reason the external
alert exists.

## `recover_cancelled_consumers!` makes the probe blind to a cancelled consumer

`Bunny::Channel#recover_cancelled_consumers!` is opt-in; neither Kicks nor
Sneakers enables it. If your application does enable it, Bunny
responds to `basic.cancel` by re-subscribing the consumer and **keeping** its
registry entry, so `any_consumers?` remains true. The "consumer was cancelled"
case then stops being detected.

Do not enable it together with this probe. If you need it for other reasons, be
aware that this probe no longer covers that failure mode.

## Broker unavailability is invisible by design

While Bunny is recovering from a network failure, the probe reports healthy. This
is deliberate: the alternative is that a ten-second broker hiccup restarts every
replica simultaneously and reconnects them all at once, which is what a
struggling broker least needs. Bunny reconnects and re-subscribes its consumers
by itself, so a restart at that moment cures nothing.

The consequence, plainly: a pod whose broker is unreachable looks healthy to
this probe. Cover it with the alert.

## The recovery exemption covers an established connection, not a failed subscribe

While Bunny is recovering from a network failure the probe reports healthy, so
that a broker hiccup does not restart every replica at once. That exemption is
asked of a `connection` object, which has to exist before it can be asked.

If the broker is unreachable at the moment a worker subscribes, there is no
connection at all: the registry stays empty and no mark is ever written. So the
cascade the exemption avoids for a live connection is still possible at startup
— broker down, every replica restarting.

The budget here is the **startup** one, not the steady-state one:

```
initialDelaySeconds + periodSeconds × failureThreshold
```

which with the values in [KUBERNETES.md](KUBERNETES.md#the-arithmetic) — no
`initialDelaySeconds`, `periodSeconds: 5`, `failureThreshold: 60` — is 300 s.
`max_age` does not appear in it, and neither do the liveness settings. Both are
about a mark that has stopped being refreshed; here there is no mark to go
stale, so the probe fails on `worker-0 missing` from its very first check, and
the container never leaves `startupProbe` for liveness to take over.

Two things take the edge off it. Kubernetes backs container restarts off
exponentially, up to five minutes, so from the outside this looks like a
flapping pod rather than a storm. And the supervisor respawning failing forks
inside the container — which is *not* throttled by anything — is now reported:
see the respawn escalation below.

## Changing the worker count at runtime is not supported

`ServerEngine` can re-read its configuration on SIGHUP and scale the fork set,
but a fork holds its own copy of that configuration from the moment it was
created. Every monitor re-declares that captured count on every tick.

After a scale-up, old forks keep declaring the old count while new forks declare
the new one. The shared `expected` file therefore depends on which fork wrote
last; it can temporarily require the new slots, or incorrectly report the old
set as complete. After a scale-down, the surviving forks keep declaring the old
count and the retired slots eventually go stale. Neither direction is safe.

If you change `workers`, restart the runner. Runtime scaling is not supported.

## A respawn loop is reported once per grace window, not once per respawn

When a fork cannot subscribe at all, the supervisor brings it back after
`start_worker_delay` — a fraction of a second — and the monitor in each
incarnation is a brand-new object. Any counter it holds is destroyed before it
can reach a threshold, which is how a real outage used to produce thousands of
identical INFO lines and not a single ERROR.

The count is therefore kept in the marks directory, which survives the fork.
The start line is logged once, repeated starts within the grace window
(`startup_grace_ticks × tick`) are silent, and after that one ERROR per window
reports the elapsed time and the number of starts:

```
[liveness] slot 0: not healthy 62s over 305 starts, expected 5 consumers
```

The number of starts is the diagnosis: it separates a slow start from a respawn
loop at a glance.

## Do not install both `kicks` and `sneakers`

The gem declares neither as a dependency, because at runtime it needs only the
`Sneakers` namespace, which both provide. But both gems own the file
`lib/sneakers.rb`, and having both in one `Gemfile` does not fail — it silently
resolves by load-path order. An application that migrated to `kicks` can end up
executing the `sneakers` code while its lockfile says otherwise, and pulling in
`sneakers` also caps the versions of `kicks` and `bunny` that Bundler will
resolve.

A loud failure gets fixed; a silent substitution does not. Keep exactly one of
the two. Bundler itself still accepts the combination, but `install!` now
rejects a process in which both gems are activated before either set of hooks is
installed.

If neither is present, `install!` raises a `LoadError` naming both with their
required versions.

## The probe reports per pod, not per queue

This is a feature rather than a defect, but it is worth stating: the probe
answers "is *this* process consuming what it is supposed to consume?" It cannot
tell you anything about the queue as a whole, about other replicas, or about
messages piling up. Backlog and throughput are monitoring concerns, not liveness
concerns, and a liveness probe that tried to cover them would restart pods for
reasons a restart cannot fix.
