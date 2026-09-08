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
loads one dependency-free Ruby file, reads the file's mtime, and exits with 0 or
1.

The probe therefore performs no network I/O and boots no framework, and the
state it reads — the mark's mtime — comes from tmpfs, which is RAM. Be precise
about the disk, though: starting the probe still loads the Ruby interpreter and
two files of this gem from the image filesystem, and those reads are ordinary
filesystem reads (usually served from page cache, but not guaranteed to be). The
honest claim is not "no disk" but *no application boot, and no disk on the path
that decides the answer* — which is what removes the defects above, not tuning.

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

The last row is the reason the registry compares its size against an expected
count rather than just checking that whatever registered is alive. Four healthy
workers out of five look perfectly fine one object at a time.

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

`recovering_from_network_failure?` is marked `@private` in Bunny's own
documentation, so an upgrade may remove it. It is therefore called through
`respond_to?`: without that guard the call would raise `NoMethodError`, `alive?`
would catch it and report *unhealthy*, and every pod would enter a restart loop
on the next Bunny upgrade. What the guard cannot preserve is the exemption
itself — if the method disappears, so does "healthy while reconnecting",
silently. That is the thing to re-check when upgrading Bunny.

## The mark files

```
<dir>/expected       how many forks the probe must wait for
<dir>/worker-<slot>  one per fork, refreshed every tick the fork is healthy
<dir>/attempt-<slot> starts of a slot that has not become healthy yet
```

**`expected` closes a startup hole.** Without it the probe would pass as soon as
any single file was fresh: fork 0 has written, fork 1 has not, and the pod looks
ready while half of it is not subscribed. Every fork writes the same value, so
they cannot disagree.

Every fork rewrites it on every tick, not only at startup. Nothing else restores
it: if the directory is wiped, `touch!` brings the slot marks back while
`expected` stays missing, and the probe reports "worker has not started" for the
rest of the pod's life. Rewriting it is also what lets a respawned set of forks
correct a count that has been lowered.

**Files are named by supervisor slot, not by PID.** A fork killed with SIGKILL
is respawned into the same slot and overwrites its own file. Had the name
contained a PID, that file would sit there stale forever and the probe would
fail permanently, turning one dead fork into a pod that can never come back.

`expected` is written through a temporary file and a `rename`, not with a plain
write. A plain write truncates first, and a probe reading in that window finds
the file empty and reports that the worker has not started. The window is real
and recurring: every fork rewrites this file on every tick, while the liveness
probe reads it on a schedule of its own. `rename` is atomic on tmpfs, so the
probe sees either the old value or the new one.

**`attempt-<slot>` is the respawn counter**, and it lives in this directory for
the single reason that the directory outlives the fork: a monitor caught in a
respawn loop is a brand-new object every few hundred milliseconds and can hold
no counter of its own. The file is removed once the slot becomes healthy, so in
steady state the directory holds only `expected` and the `worker-<slot>` marks;
what the counter is for is in
[LIMITATIONS.md](LIMITATIONS.md#a-respawn-loop-is-reported-once-per-grace-window-not-once-per-respawn).

The *contents* of `worker-<slot>` (timestamp, pid, slot) exist only for a human
running `kubectl exec ... cat`. The probe decides on mtime alone.

The directory must be on tmpfs — in Kubernetes, an `emptyDir` with
`medium: Memory`. Put it on a real disk and the probe starts depending on the
disk again, which was defect number two.

## Why the heartbeat file has no `require` of its own

The probe loads exactly one file and nothing else. Measured over 30 invocations
each; absolute values depend on the hardware, but the ratios do not:

| | per invocation |
|---|---|
| `ruby --disable-gems -e ''` — bare interpreter | 10 ms |
| `ruby -e ''` — RubyGems initialized | 38 ms |
| the probe, with `--disable-gems` and an explicit path | 10.5 ms |
| the probe, found through RubyGems | 43 ms |
| **`bundle exec ruby -e ''`** | **300 ms** |

Subtract the baselines and the probe's own work is a **few milliseconds**.
Everything else is interpreter startup, and 28 ms of that is RubyGems
initializing.

Three consequences follow. `bundle exec kicks-liveness` is the portable
default; most of its runtime is Bundler startup rather than the check itself.
When the gem is installed in `GEM_HOME`, RubyGems can find it with a plain
`require` for under 50 ms. Skipping RubyGems entirely is faster still, but it
requires naming the path to the gem's `lib` directory; see
[KUBERNETES.md](KUBERNETES.md) for when that trade is worth making.

Keeping the probe's path through the heartbeat file free of `require`
statements — and the file free of references to the rest of the gem — is what
makes all three possible. The single `require` the file does contain,
`fileutils`, is lazy and sits in the directory-creation branch that only the
worker ever reaches.

## Where the hooks attach

Two `prepend`s, installed by `KicksLiveness.install!` (automatically through a
Railtie in Rails), covering four methods:

- `Sneakers::Worker#run` — register in the registry *after* `super`, so a worker
  whose `subscribe` raised never registers and the probe honestly fails.
- `Sneakers::Worker#stop` — deregister *before* `super`.
- `Sneakers::WorkerGroup#after_fork` — start the monitor thread *after* `super`.
- `Sneakers::WorkerGroup#stop` — record that the shutdown is deliberate, *before*
  `super` starts unsubscribing.

`after_fork` rather than `run`, even though `run` is where the monitor must
ultimately live: `Sneakers::WorkerGroup#run` calls `after_fork` as its very first
statement and only then resolves `worker_classes`, so hooking `after_fork` is the
earliest point in the fork at which the application's own `after_fork` hook has
already run. That matters because resolving the expected consumer count may run
application code — under `sneakers:active_job` the set is a callable registry —
and the standard use of `after_fork` is re-establishing the connections a fork
inherited. Resolving the set first would run that code against a fork that is not
ready yet, and the `rescue` around the start would then leave the pod with no
monitor at all. A spec asserts this ordering against the real worker gem, so an
upgrade that reorders `run` fails in CI rather than in production.

`ServerEngine::Server#create_worker` calls `w.extend(@worker_module)`: the
`WorkerGroup` module lands in the singleton class of the *instance*, not as an
`include` in a class. A `prepend` to the module still sits ahead of it in that
lookup chain, which is what makes the hook work; `worker_id` and `config` come
from `ServerEngine::Worker`. Verified on serverengine 2.4.0, and covered by a
spec that asserts the order in `ancestors` — this is the most fragile assumption
in the gem, so it fails in CI rather than in production.

Slot numbers come from `worker_id`, which is the index into ServerEngine's
`@monitors` array, and both `start_new_worker(wid)` and `restart_worker(wid)`
reuse the same index. That is what the slot-not-PID scheme relies on.

The monitor thread is created inside the fork, because threads do not survive
`fork`. Starting it earlier would accomplish nothing. For the same reason the
registry initializes its array and mutex at file-load time: that happens once,
single-threaded, before any fork, so no lazy initialization is needed and none
can race.

In Rails the hooks are installed from a Railtie, and from `to_prepare` rather
than an `initializer`. An application's `lib` is normally managed by Zeitwerk and
reloadable, and reloadable constants must not be referenced while the
application is initializing.

Starting the monitor is wrapped in a `rescue`: instrumentation has no right to
prevent a worker from starting. `Dir.mkdir` raises `Errno::EROFS` if the marks
directory was never mounted, and resolving the worker set runs application code.
The worst outcome should be a missing mark and a pod restart, never a pod that
stays up with silent queues.

### The expected consumer count is not configured

It is derived from `config[:worker_classes]` — the very set from which the
worker gem builds its workers. The queue list is therefore never duplicated and
cannot drift from the application's configuration.

That value is an array of classes under `sneakers:run` and a callable registry
under `sneakers:active_job`, so it is resolved with a `respond_to?(:call)`
check.

## What is configurable, and where

| | Where | Why |
|---|---|---|
| `logger`, `enabled`, `startup_grace_ticks` | application config block | only the worker needs them |
| `tick` | either, and the config block wins | only the worker reads it, so two sources cannot contradict each other |
| `dir`, `max_age` | environment variables **only** | the probe is a separate process |

`dir` and `max_age` are deliberately *not* settable from the application. The
probe is launched by the kubelet as its own process; it never reads, and cannot
read, the application's initializer. If those two values were configurable in
both places, a mismatch between what the worker writes and what the probe
expects would pass unnoticed — and that mismatch is silent by nature: the worker
would look fine and the probe would look broken. Making them read-only from the
application removes the failure mode instead of documenting it. A spec asserts
that `Configuration` does not respond to `dir=` or `max_age=`.

`tick` is the opposite case and may be set from either side, because only the
worker ever reads it: with a single reader there is nothing for a mismatch to
happen between. `KICKS_LIVENESS_TICK` supplies the initial value and the
configuration block overrides it, so `config.tick = 5` wins over the variable.

Values arriving from a ConfigMap are parsed defensively: garbage falls back to
the default rather than crashing the worker, and an empty string counts as
"unset" — in a ConfigMap that is what you get by declaring a key and leaving it
blank.

`max_age` and `tick` are durations, so a value must be parseable *and* positive.
Zero and negative numbers are the more dangerous half: they parse perfectly
well, a tick of zero turns the monitor into a hot loop, and a negative `max_age`
makes every mark stale on arrival, so the probe can never pass again. They fall
back to the default too.

Setting `tick` from the application is held to a stricter standard: a
non-positive value raises `ArgumentError`. The environment gets a silent fallback
because a ConfigMap typo must not bring a worker down, whereas an initializer is
code, and code should fail loudly at boot, where the developer is looking.

The logger defaults to `Sneakers.logger` but is resolved lazily, because at the
time the configuration object is built it may not be set up yet.

## Logging: events, not the pulse

The pulse lives in the mtime of a file; writing a log line every tick would only
add noise. What gets logged is transitions.

| Event | Level |
|---|---|
| started, with the effective settings | INFO |
| waiting for consumers | INFO |
| became healthy | INFO |
| shutting down | INFO |
| still not healthy after `startup_grace_ticks` ticks | ERROR |
| was healthy, became unhealthy | ERROR |
| a slot respawning without ever becoming healthy, once per grace window | ERROR |
| the monitor thread caught an exception | ERROR |
| the monitor could not be started at all | ERROR |

ERROR is reserved for genuine failure. A logger typically comes up with
`LOG_LEVEL` defaulting to `error`, so anything important must survive that
filter — while an ordinary pod start must not emit ERROR on every deploy, or an
alert on ERROR logs fires on every rollout and is promptly muted.

A graceful shutdown is the other half of that rule. `Sneakers::Worker#stop`
unsubscribes and then waits for the thread pool to drain, which takes as long as
the longest in-flight job — and the registry empties at the start of it. Judged
by the consumer count that is indistinguishable from a fault, so every single
deploy would emit an ERROR. From `WorkerGroup#stop` onwards the predicate is
therefore suspended: the monitor says so once at INFO and keeps the mark fresh,
so a slow drain gets the full `terminationGracePeriodSeconds` instead of having
the probe cut it short at `max_age`.

The startup grace exists because a slow start and a start that will never finish
look identical for the first few ticks. Once the grace expires, staying silent
would mean a pod that never comes up never says so — hence exactly one ERROR,
not one per tick.
