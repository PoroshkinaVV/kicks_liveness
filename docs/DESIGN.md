# Design

Why this gem is shaped the way it is. If you only want to deploy it, read
[KUBERNETES.md](KUBERNETES.md) instead.

## The problem with the usual liveness probe

The common implementation is a rake task, invoked by the kubelet through `exec`,
that boots the application and asks the broker for `consumer_count` on the
queues it expects to be served. It has four defects, and three of them cannot
be tuned away.

**It is expensive.** Booting a full Rails application every few seconds, inside
the worker's own cgroup. A probe measured at 2.7 s of CPU per invocation on a
15 s period consumes `2.7 / 15 ≈ 0.18` of a core continuously, per pod, forever.
Multiply by your replica count and compare it against the CPU request of the
container; on a small worker fleet the probe can easily outweigh the work.

**It depends on the disk.** Loading code means reading files. A disk that stalls
for a few seconds stretches the probe past `timeoutSeconds`, and the kubelet
kills a pod that was perfectly healthy. A stalling disk is one of the most
common causes of false restarts, and a probe that reads from it converts that
cause into an outage.

**It cascades.** A liveness probe that checks an external dependency makes that
dependency a participant in your restart logic. The broker hiccups for ten
seconds, every replica fails its probe at the same moment, and the whole fleet
restarts simultaneously — reconnecting all at once, which is exactly what a
struggling broker least needs.

**It measures the wrong thing.** `consumer_count` is a property of a *queue*,
not of a *pod*. With two replicas, one healthy consumer keeps the count above
zero while the other replica is hung and consuming nothing. The metric that is
supposed to detect a dead pod is structurally blind to it.

## The inversion

Turn the data flow around. The worker knows its own state better than anything
outside it can, so let the worker publish and let the probe read.

Every `tick` seconds (10 by default) the worker checks, **in its own memory**,
that its consumers are still subscribed, and touches a file on tmpfs. The probe
loads one dependency-free Ruby file, checks the marks' container generation and
mtimes, and exits with 0 or 1.

The probe therefore performs no network I/O and boots no framework, and the
state it reads — the generation and mark mtimes — comes from procfs and tmpfs.
Be precise about the disk, though: starting the probe still loads the Ruby
interpreter and two files of this gem from the image filesystem, and those reads
are ordinary filesystem reads (usually served from page cache, but not
guaranteed to be). The honest claim is not "no disk" but *no application boot,
and no disk on the path that decides the answer* — which is what removes the
defects above, not tuning.

## The health predicate

Computed only over Bunny objects held in the worker process:

```ruby
channel = worker.queue.channel
return false if channel.nil?

connection = channel.connection
return true if recovering?(connection)

channel.open? && connection.open? && channel.any_consumers?
```

| State | Verdict | Why |
|---|---|---|
| consumers present, channel open | healthy | — |
| `channel` still `nil` | unhealthy | subscription has not happened yet; `startupProbe` holds the pod |
| Bunny recovering from a network failure | **healthy** | Bunny reconnects and re-subscribes on its own; restarting now cures nothing and adds a reconnect storm |
| connection open, no consumers | unhealthy | the worker silently stopped consuming — a restart is the only cure |
| not the whole set subscribed | unhealthy | a worker that quietly dropped out would otherwise leave the probe green |

The expected count catches partial subscription: four healthy workers out of
five must still make the process unhealthy.

### Nothing here talks to the broker

Every call in the predicate reads process-local state. Verified against Bunny 3.2.0:

| Call | Implementation |
|---|---|
| `worker.queue.channel` | `attr_reader` on `Sneakers::Queue` |
| `channel.connection` | `attr_reader` on `Bunny::Channel` |
| `connection.recovering_from_network_failure?` | `@recovery_mutex.synchronize { @recovering_from_network_failure }` |
| `channel.open?` | `@status == :open` |
| `connection.open?` | status under `@status_mutex`, then `@transport.open?` → `@socket && !@socket.closed?` |
| `channel.any_consumers?` | `@consumer_mutex.synchronize { @consumers.any? }` |

`IO#closed?` reports the state of the IO object in this process; it is not a
syscall and not a packet. By contrast, `consumer_count` is a genuine round trip —
a passive `Queue.Declare` or an HTTP API call. That round trip is what this gem
does not make.

The predicate learns that a consumer was cancelled because RabbitMQ sends
`basic.cancel` and Bunny deletes the consumer from its own registry. That is a
push, not a poll — which is what makes an in-memory predicate possible at all,
and also where its limits come from. See [LIMITATIONS.md](LIMITATIONS.md).

`recovering_from_network_failure?` is private Bunny API. The `respond_to?` guard
avoids turning its removal into a rescued `NoMethodError` and an unhealthy
verdict on every tick. Removal would still disable the recovery exemption
silently; re-check this API when upgrading Bunny.

## The mark files

```
<dir>/expected         how many forks the probe must wait for
<dir>/generation       which container incarnation wrote this heartbeat
<dir>/worker-<slot>    one per fork, refreshed every tick the fork is healthy
<dir>/attempt-<slot>   starts of a slot that has not become healthy yet
<dir>/topology-unsafe  the PID namespace is not this container's: fail closed
<dir>/topology-report  what the worker has already reported about it, once
```

**`expected` prevents partial startup from passing.** Checking only existing
marks could accept fork 0's fresh mark before fork 1 has subscribed. Declaring
the count tells the probe which marks must exist, not just which are fresh.
With a fixed runner configuration, every fork declares the same count.
Re-declaring on each tick also restores `expected` if the directory is
wiped; refreshing slot marks alone would leave the probe permanently unhealthy.
Live worker-count changes remain
[unsupported](LIMITATIONS.md#changing-the-worker-count-at-runtime-is-not-supported).

**`generation` rejects inherited heartbeats.** With usable Linux procfs and a
container-private PID namespace, the worker and exec probe derive it from the
mount namespace and PID 1 start time. Both `generation` and every slot mark must
match the current incarnation, so an `emptyDir` preserved across a container
restart cannot pass `startupProbe` until all replacement forks publish. No
application cache is removed. Procfs and PID-topology limits are described in
[LIMITATIONS.md](LIMITATIONS.md#container-generations-need-linux-procfs-and-a-private-pid-namespace).

**`topology-unsafe` carries terminal evidence from the worker.** Each participant
compares `/proc/1/ns/mnt` with `/proc/self/ns/mnt` independently. A worker that
proves them different writes this file instead of a heartbeat; the probe checks
it before `expected`, generation, or freshness. Omitting a new generation would
leave inherited marks eligible for acceptance. Weaker evidence never clears
this file.

**`topology-report` deduplicates worker diagnostics across forks.** The probe
ignores it. Claims lock the complete read-compare-write operation; atomic rename
alone cannot prevent concurrent claims. Clearing by truncation keeps every fork
locking the same inode.

**Slot names survive fork replacement.** A respawn overwrites its predecessor's
mark. PID-based names would leave stale files that permanently fail the probe.

`expected` and slot marks are published through temporary files and `rename`.
Concurrent probes therefore see complete old or new contents, never a truncated
count or a mark missing its generation. Temporary filenames include the writer's
PID so concurrent forks cannot overwrite one another's temporary files.

**`attempt-<slot>` persists an unhealthy run across fork respawns.** Its
generation rejects counts from a previous container when one can be derived.
The first healthy tick removes it. Reporting windows and generation-less scope
are explained in
[LIMITATIONS.md](LIMITATIONS.md#a-respawn-loop-is-reported-once-per-grace-window-not-once-per-respawn).

The timestamp, pid, and slot in `worker-<slot>` exist for a human running
`kubectl exec ... cat`. Its generation is part of the probe contract; freshness
still comes from mtime.

Use tmpfs — an `emptyDir` with `medium: Memory` in Kubernetes — to keep mark
reads independent of disk stalls.

## Why the heartbeat file has no `require` of its own

The probe entry point loads only `heartbeat.rb`. Recorded over 30 invocations
each; timings vary with the runtime and hardware:

| | per invocation |
|---|---|
| `ruby --disable-gems -e ''` — bare interpreter | 10 ms |
| `ruby -e ''` — RubyGems initialized | 38 ms |
| the probe, with `--disable-gems` and an explicit path | 10.5 ms |
| the probe, found through RubyGems | 43 ms |
| **`bundle exec ruby -e ''`** | **300 ms** |

Interpreter and dependency startup dominate these measurements. `bundle exec`
is the portable default; direct loading depends on where the image installs
the gem, as described in [KUBERNETES.md](KUBERNETES.md#where-your-image-puts-its-gems).
`heartbeat.rb` therefore references no other gem code and requires `fileutils`
only in the worker's directory-creation branch. Worker-only counters and report
deduplication live in `Attempts` and `TopologyReport` so their code and requires
stay outside the probe's load path.

## Where the hooks attach

Two `prepend`s, installed by `KicksLiveness.install!` (automatically through a
Railtie in Rails), covering four methods:

- `Sneakers::Worker#run` — register in the registry *after* `super`, so a worker
  whose `subscribe` raised never registers and the probe honestly fails.
- `Sneakers::Worker#stop` — deregister *before* `super`.
- `Sneakers::WorkerGroup#after_fork` — start the monitor thread *after* `super`.
- `Sneakers::WorkerGroup#stop` — record that the shutdown is deliberate, *before*
  `super` starts unsubscribing.

`WorkerGroup#run` calls `after_fork` before resolving `worker_classes`. Starting
after that hook lets the application restore inherited connections before the
consumer count runs application code. This matters for the callable registry
used by `sneakers:active_job`; resolving it too early can prevent monitor startup.
A spec pins this ordering against the worker gem.

ServerEngine 2.4.0 uses `w.extend(@worker_module)`, placing `WorkerGroup` in the
instance's singleton-class chain. Prepending to the module still intercepts its
methods; an `ancestors` spec verifies that assumption. `worker_id` and `config`
come from `ServerEngine::Worker`.

Slot numbers come from `worker_id`, which is the index into ServerEngine's
`@monitors` array, and both `start_new_worker(wid)` and `restart_worker(wid)`
reuse the same index. That is what the slot-not-PID scheme relies on.

The monitor thread is created inside the fork because threads do not survive
`fork`. The registry's array and mutex are initialized at load time, before
forking, avoiding races during lazy initialization.

The Rails Railtie registers installation through `to_prepare`, allowing access
to reloadable worker constants after initialization. Startup exceptions, from
either application code or an unwritable marks directory, are logged without
preventing the worker from starting. The probe remains responsible for detecting
a missing or stale heartbeat.

### The expected consumer count is not configured

`config[:worker_classes]` is the set the worker gem itself consumes: an array
under `sneakers:run`, a callable registry under `sneakers:active_job`. Resolve it
with `respond_to?(:call)` rather than maintaining a separate queue list.

## What is configurable, and where

| Setting | Where | Why |
|---|---|---|
| `logger`, `enabled`, `startup_grace_ticks` | application config block | only the worker needs them |
| `tick`, `shutdown_grace` | either, and the config block wins | only the worker reads them, so two sources cannot contradict each other |
| `dir`, `max_age` | environment variables **only** | the probe is a separate process |

The exec probe cannot read an application initializer, so `dir` and `max_age`
have one source: the environment. Specs reject application setters for both.
Only the worker reads `tick` and `shutdown_grace`, so initializer values may
override their environment values without contradicting the probe.

Environment durations must be positive integers; missing, empty, unparseable,
zero, and negative values use defaults. If the effective tick is at least
`max_age`, it warns on stderr and uses the default tick when safe, or half of
`max_age` otherwise. The warning is deferred until the tick is read, so an
initializer override or a disabled monitor does not produce a misleading WARN.

`KICKS_LIVENESS_SHUTDOWN_GRACE` defaults to 60 seconds. Its initializer override
accepts positive finite real numbers. Set it to at least the deployment's
`terminationGracePeriodSeconds`, which the gem cannot discover from a signal.

Invalid ConfigMap input falls back so a deployment typo does not prevent worker
startup. Initializer values are application code: invalid values raise
`ArgumentError` at boot, where the developer can fix the error, rather than
silently substituting a default. `tick` must be a positive number smaller than
`max_age`, and `startup_grace_ticks` a positive integer. The latter is compared
with an integer counter; accepting a float or zero would disable escalation.

The default logger is resolved lazily from `Sneakers.logger`, which may be unset
during configuration. Logger exceptions are swallowed at the logging boundary
so they cannot prevent heartbeat publication or stop the monitor. No fallback
uses the same broken logger.

## Logging: events, not the pulse

The pulse lives in the mtime of a file; writing a log line every tick would only
add noise. What gets logged is transitions.

| Event | Level |
|---|---|
| started, with the effective settings | INFO |
| the PID topology could not be verified, or yielded no generation | WARN |
| waiting for consumers | INFO |
| became healthy | INFO |
| shutting down | INFO |
| still not healthy after `startup_grace_ticks` ticks | ERROR |
| was healthy, became unhealthy | ERROR |
| a slot respawning without ever becoming healthy, once per grace window | ERROR |
| the PID topology is proven unsupported | ERROR |
| the monitor thread caught an exception | ERROR |
| the monitor could not be started at all | ERROR |

`topology-report` deduplicates only the three topology results: `unverifiable`,
`unavailable`, and `unsafe`. Their warning frequency, probe output, and recovery
are described in
[LIMITATIONS.md](LIMITATIONS.md#container-generations-need-linux-procfs-and-a-private-pid-namespace).
Loop and startup exceptions do not use that flag.

ERROR must survive the usual error-level logger filter, while normal startup
and deliberate shutdown remain INFO. On shutdown the monitor suspends its
predicate until a monotonic deadline: the first `Registry.stopping!` records the
stop time, and the monitor adds `shutdown_grace`. A delayed tick or repeated
callback cannot renew it. At expiry it logs one ERROR and stops `touch!` while
continuing `declare!`. Nothing is persisted, so a replacement fork does not
inherit a sibling's shutdown. Mark freshness still uses wall time; see the
[timing boundary](LIMITATIONS.md#graceful-shutdown-has-a-finite-heartbeat-exemption).

Startup grace postpones the error for a slow initial subscription; a surviving
monitor reports once when it expires. Fork-respawn loops use the persistent
counter and reporting windows described in
[LIMITATIONS.md](LIMITATIONS.md#a-respawn-loop-is-reported-once-per-grace-window-not-once-per-respawn).
