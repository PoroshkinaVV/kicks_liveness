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

The probe reports healthy while Bunny recovers an established connection and
re-subscribes consumers. This avoids restarting every replica during a broker
outage, but also means an unreachable broker is invisible to this probe. Cover
that case with the external consumer alert.

## The recovery exemption covers an established connection, not a failed subscribe

The exemption requires a connection object. If the initial subscription fails,
the worker never registers and no mark is written. A broker outage at startup
can therefore restart every replica even though an established connection would
be exempt.

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

## Graceful shutdown has a finite heartbeat exemption

`Sneakers::WorkerGroup#stop` removes consumers before waiting for their thread
pools to drain. `Registry.stopping!` therefore suspends the consumer predicate
before the first worker stops, allowing an orderly drain to keep its heartbeat
fresh without reporting a consumer failure on every deploy.

The exemption lasts for `shutdown_grace` seconds from the first stop callback
(default 60). Set `KICKS_LIVENESS_SHUTDOWN_GRACE` or `config.shutdown_grace` to at
least the deployment's `terminationGracePeriodSeconds`. During pod deletion the
kubelet still owns the outer termination deadline. The gem cannot determine
whether a SIGTERM came from the kubelet, an operator, or another process.

At the deadline, the monitor logs one ERROR and stops refreshing the slot mark.
It keeps declaring the expected fork count, so an existing mark eventually
fails as `worker-<slot> stale`, rather than claiming that the worker never
started. The monitor does not kill the process or resume checking consumers.
This bounds the formerly indefinite healthy result when an out-of-band SIGTERM
leaves a process stuck draining with no consumers.

Expiry is not an immediate probe failure: the last mark must still exceed
`max_age`. Under normal clock progression, the bound from stop notification to
restart eligibility is `shutdown_grace + max_age`; actual restart also depends
on the probe period and failure threshold. The first stop time and deadline are
process-local, so repeated stop callbacks do not renew them and a sibling
replacement fork starts without them.

The deadline uses the monotonic clock. A wall-clock jump cannot shorten or
extend the exemption, but it can change mark staleness: the probe still compares
filesystem mtime with wall time. Keep the external consumer alert enabled; the
shutdown grace and the probe budget deliberately allow a period with no
consumers before a restart.

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
is the node's init process. Neither restarts when the worker container does.
If the replacement container also receives the same mount namespace inode,
the complete identifier repeats and an inherited fresh mark can satisfy the
0.1.2 startup probe.

Rejection in 0.1.3 depends on procfs access. On the measured Kubernetes node,
default capabilities left shared PID `unverifiable` and host PID `unavailable`;
node init reported start time zero. Adding `CAP_SYS_PTRACE` made shared PID
provably `unsafe`. This is not a recommendation to add the capability.
The full restart reproduction and Kubernetes measurement are in
[VERIFYING.md](VERIFYING.md#12-shared-and-host-pid-topology-outcomes).

### Proven unsafe: the probe fails, and keeps failing

Both links readable and different is proof that PID 1 belongs to something
outside this container. The probe exits 1 with

```
unsupported PID topology: pod must not set shareProcessNamespace or hostPID
```

Procfs access can differ between the worker and probe. A worker that proves the
topology unsafe publishes `topology-unsafe` instead of a heartbeat; a probe
rejects either that file or its own unsafe result before checking marks.
Inherited generations and another fork's marks cannot override the verdict.

The worker logs the reason and recovery at ERROR once for the uninterrupted
unsafe state, across forks and container restarts sharing the volume. Later
containers in that pod therefore do not repeat the ERROR; read the verdict from
the kubelet's `Unhealthy` event or `topology-unsafe`.

This state is terminal for the marks volume. Neither PID setting can change on
a live pod, and its `emptyDir` dies with it. **Recovery is recreating the pod
without those settings.** Until then probes fail and the container restarts.
Unreadable namespace links do not establish this verdict; they take a degraded
branch below.

### Unverifiable: the 0.1.2 guarantee, and one warning

Reading `/proc/1/ns/mnt` is a ptrace-level operation and may be denied, including
when PID 1 runs as a different user. Denial cannot distinguish a valid private
PID namespace from an unsupported topology. If the other procfs entries yield a
generation, the probe retains its 0.1.2 check and output; the worker logs:

```
WARN [liveness] slot 0: PID topology unverified (cannot read /proc/1/ns/mnt (Errno::EACCES)):
the container generation still scopes the heartbeat, but shareProcessNamespace and hostPID
cannot be ruled out
```

Read this as unverifiable, not safe: an unsupported topology still has the
0.1.2 inherited-heartbeat weakness. The WARN is once per derived generation,
across fork respawns. The measured Kubernetes shared-PID case reached this state;
its credentials and capability comparison are recorded in VERIFYING.md above.

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

If `/proc/self/ns/mnt` or `/proc/1/stat` cannot yield a generation, the probe
falls back to the 0.1.1 freshness-only check and may accept fresh inherited
marks. The worker warns once for the uninterrupted unavailable state. A verified
topology clears the report flag so a later degradation is reported again:

```
WARN [liveness] slot 0: no container generation (cannot read /proc/1/stat (Errno::EACCES)):
falling back to freshness only, which cannot reject a heartbeat inherited from a previous
container
```

A zero start time uses the detail `PID 1 start time is zero; possible hostPID or
virtualized procfs` in that warning. The field counts clock ticks after boot,
so zero is valid, not a parse error. It was observed for node init in a host-PID
pod, but may also be exposed for a legitimate PID 1 by virtualized procfs.
Without measurements of those runtimes, zero alone remains `unavailable`.

Off Linux the same freshness-only fallback is **silent**, an intentional
compatibility mode. Degraded Linux warnings also stay off the probe's stdout:
they belong in the worker log, not repeated beside unrelated failures in
`Unhealthy` events. A proven unsafe topology is different: it is the probe's
verdict.

### The probe must run in the worker's container

The worker and its exec probe must run in the **same container**. A neighbouring
sidecar can mount the same `emptyDir`, but it has a different mount namespace and
therefore treats the worker's marks as belonging to another container.
Kubernetes exec probes already run inside the container they check; do not move
`kicks-liveness` into a separate health sidecar.

## A respawn loop is reported once per grace window, not once per respawn

The supervisor respawns a fork that cannot subscribe after `start_worker_delay`,
potentially before its monitor reaches startup grace. `attempt-<slot>` therefore
keeps the count and window start outside process memory. The first incarnation
logs startup, further starts within `startup_grace_ticks × tick` are silent, and
each expired window produces one ERROR with elapsed time and cumulative starts:

```
[liveness] slot 0: not healthy 62s over 305 starts, expected 5 consumers
```

The generation in the file rejects an earlier container's count. A replacement
logs its own `started:` and cannot escalate over starts it did not take; the
first healthy tick clears the counter. Without a generation, the old volume-wide
scope remains: read it as starts since this slot was last healthy in the pod.

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
