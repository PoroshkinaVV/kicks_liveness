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

## Container generations need Linux procfs and a private PID namespace

Kubernetes keeps an `emptyDir` across restarts of a container in the same pod.
To stop the next container inheriting a fresh heartbeat, the worker and its exec
probe independently identify their shared incarnation from Linux procfs: the
mount namespace plus PID 1 start time. No application cache is removed.

That is an incarnation only where the container owns PID 1. With
`shareProcessNamespace: true` PID 1 is the pod sandbox; with `hostPID: true` it
is the node's init process. Neither restarts when the worker container does, so
the start-time half of the identifier stays constant — and the mount namespace
inode does not rescue it, because procfs hands out the lowest free inode and a
quiet restart normally gets back the one it just released. Both halves repeat,
so under the 0.1.2 rule an inherited fresh mark satisfied the startup probe.
Watched, computing that rule by hand after a container restart, in
[VERIFYING.md](VERIFYING.md#12-a-shared-or-host-pid-namespace-is-rejected):

```
shared-pid: 0.1.2 generation before=mnt:[4026532693]:17207878 after=mnt:[4026532693]:17207878
host-pid:   0.1.2 generation before=mnt:[4026532699]:105      after=mnt:[4026532699]:105
```

Since 0.1.3 that is detected rather than merely documented. Each side compares
`/proc/1/ns/mnt` with `/proc/self/ns/mnt`, and what it can prove decides what
happens.

### Proven unsafe: the probe fails, and keeps failing

Both links readable and different is proof that PID 1 belongs to something
outside this container. The probe exits 1 with

```
unsupported PID topology: pod must not set shareProcessNamespace or hostPID
```

Neither participant owns that verdict alone, because procfs access is local to a
process and the worker's credentials need not match the probe's. So a worker
that can prove it publishes `topology-unsafe` in the marks directory instead of
a heartbeat, and every probe reads that first — before `expected`, before its
own procfs, before any freshness check. Proof from either side is enough, and
nothing weaker takes it back: an inherited `generation` file may still be lying
in the volume, and marks published by another fork are not evidence of safety.

The worker reports it once at ERROR, naming the detail it proved and the way
out. Once, not once per fork and not once per respawn: a fork that also cannot
subscribe comes back every few hundred milliseconds, and a topology it cannot
change would otherwise fill the log. There is no honest incarnation boundary to
key that promise to — that the incarnation cannot be trusted is the finding
itself — so a later container in the same pod stays silent and the verdict is
read from the probe, in the kubelet's `Unhealthy` event, and from the file.

The state is terminal for the life of the marks volume, and deliberately so.
Neither setting can be changed on a live pod, and the `emptyDir` is destroyed
with the pod, so there is no supported transition from this state back to a safe
one. **Recovery is recreating the pod without those settings.** Until then the
container fails its probes and restarts, which is the honest outcome: the
alternative is a pod that looks healthy while nothing guarantees the heartbeat
belongs to the process that is running.

### Unverifiable: the 0.1.2 guarantee, and one warning

Reading another process's namespace link is a ptrace-level operation, so
`/proc/1/ns/mnt` can be unreadable — most simply when PID 1 runs as a different
user. That is *not* proof of anything, and treating it as proof would fail a
correctly configured private-PID deployment closed.

So the generation is derived and checked exactly as 0.1.2 checked it, the probe
behaves and prints exactly as it otherwise would, and the worker logs one
warning:

```
WARN [liveness] slot 0: PID topology unverified (cannot read /proc/1/ns/mnt (Errno::EACCES)):
the container generation still scopes the heartbeat, but shareProcessNamespace and hostPID
cannot be ruled out
```

Read that as unverifiable, not as safe: if the pod does set one of the two, this
is the state it lands in whenever the link cannot be read, and the 0.1.2
weakness above is then still present. It is warned about once per container
incarnation, not once per fork, because a respawn loop would otherwise turn one
lost guarantee into thousands of identical lines.

There is a narrower startup window when the worker and probe have asymmetric
access: the worker can prove the topology unsafe, but the probe cannot. Before
that worker reaches the monitor and publishes `topology-unsafe`, the probe can
accept inherited marks only if the volume already contains a fresh heartbeat
from an older worker, or from one that also could not prove the topology. Both
conditions are required. A normal Kubernetes exec probe inherits the
container's credentials and reaches the same procfs verdict itself; after a
0.1.3 worker has proved the topology, `topology-unsafe` also survives every
later restart in the same documented `emptyDir`. The residual window therefore
requires an in-place restart that also changes the image or effective access,
or a marks volume that outlives the pod contrary to this setup. In that case the
probe retains the explicitly degraded 0.1.2 guarantee until the current worker
publishes its verdict.

### No generation at all

If procfs yields no identifier — `/proc/self/ns/mnt` or `/proc/1/stat` missing,
unreadable, or unparseable — the guard falls back to the 0.1.1 freshness-only
check, which cannot tell a fresh mark left by the previous container from one
written by this process. The worker warns once for as long as that state lasts,
and a later successful derivation clears the flag so a new degradation is
reported again:

```
WARN [liveness] slot 0: no container generation (cannot read /proc/1/stat (Errno::EACCES)):
falling back to freshness only, which cannot reject a heartbeat inherited from a previous
container
```

Off Linux there is no procfs to read, and the same fallback applies **silently**:
that is an intentional compatibility mode — the gem outside a Linux container —
rather than a Linux environment where a value that exists in principle could not
be read. Linux Kubernetes, Docker, and Nomad containers expose the required
entries under their normal configuration.

Neither fallback is ever reported on the probe's stdout. An exec probe's output
reaches a human only through the kubelet's `Unhealthy` event, where a diagnostic
repeated on every invocation would sit beside reasons it has nothing to do with.
A proven unsafe topology is different: there the verdict *is* the probe's answer.

### The probe must run in the worker's container

The worker and its exec probe must run in the **same container**. A neighbouring
sidecar can mount the same `emptyDir`, but it has a different mount namespace and
therefore treats the worker's marks as belonging to another container.
Kubernetes exec probes already run inside the container they check; do not move
`kicks-liveness` into a separate health sidecar.

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

The count belongs to a container, not to a volume: each `attempt-<slot>` file
carries the generation that wrote it, and one from another generation counts as
no previous start. A replacement container therefore logs its own `started:`
line and never escalates over starts it did not take. Where there is no
generation to write — off Linux, or where procfs did not yield one — the counter
keeps its volume-wide 0.1.1 scope, because there is nothing honest to scope it
to; treat the count there as "starts since this slot was last healthy in this
pod".

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
