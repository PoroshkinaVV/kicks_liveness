# kicks_liveness

A liveness probe for [Kicks](https://github.com/ruby-amqp/kicks) workers (and
for its predecessor Sneakers): the worker itself publishes a liveness mark to
tmpfs, and the probe only reads it.

## Documentation

- [docs/SETUP.md](docs/SETUP.md) — installation and wiring: Rails, Sinatra,
  Hanami, Roda, and no framework at all; what `install!` does and when to call
  it.
- [docs/DESIGN.md](docs/DESIGN.md) — why the gem is built this way: the health
  predicate, the mark files, slots instead of PIDs, where the hooks attach, what
  is configurable and why `dir` and `max_age` live in the environment only.
- [docs/KUBERNETES.md](docs/KUBERNETES.md) — the manifest, the budget
  arithmetic, verifying on a live pod, the alert on consumers.
- [docs/LIMITATIONS.md](docs/LIMITATIONS.md) — where the in-memory predicate
  stops being truthful.
- [docs/VERIFYING.md](docs/VERIFYING.md) — the runbook that causes the real failures on a local cluster: what was observed, and how long each took.

## Why

The usual implementation is a rake task that boots Rails and asks RabbitMQ for
`consumer_count`. It has three defects that cannot be fixed in place:

1. **It is expensive.** Booting Rails every few seconds inside the worker's own
   cgroup. On one real service this cost 2.7 s per invocation on a 15 s
   period — 38% of the container's CPU request, around the clock.
2. **It depends on the disk.** A disk that stalls for a few seconds stretches
   the boot past `timeoutSeconds`, and the kubelet kills a healthy pod.
3. **It cascades.** A liveness probe that checks an external dependency turns a
   broker hiccup into every replica restarting at once, finishing the broker off.

On top of that, `consumer_count` is a metric of the **queue**, not of the pod:
with two replicas the live one covers for the stalled one, and the probe cannot
tell.

This gem inverts that. Every 10 seconds the worker checks, against the Bunny
objects **in its own memory**, that its consumers are in place, and touches a
file. The standard probe invocation took 156 ms in the fixture container, makes
no network call, boots no framework, and reads the state it judges from tmpfs,
which is RAM. It does still load Bundler, the interpreter and the gem's probe
files from the image filesystem, so the disk is not out of the picture
altogether — it is reduced to a small process startup instead of a full
application boot on every probe.

## Installation

```ruby
gem 'kicks_liveness'
```

You need `kicks` (>= 3.0) **or** `sneakers` (>= 2.11). Neither is declared as a
dependency of this gem, on purpose: at runtime only the `Sneakers` namespace is
required, and both gems provide it. If neither is present, `install!` raises a
`LoadError` naming both. Both floors are exercised in CI at their exact
versions, not just through a `~>` that resolves to the newest release.

Keeping both gems in one `Gemfile` is **not** allowed, and nothing enforces
that: not Bundler, not a crash at boot. Both own the file `lib/sneakers.rb`, so
one silently wins the load path. An application that has moved to `kicks` would
keep executing `sneakers` 2.12 code while its `Gemfile.lock` claims otherwise.
`sneakers` also caps the `kicks` and `bunny` versions.

The gem installs its hooks itself through a Railtie. Outside Rails, call
`KicksLiveness.install!` before the runner starts: the tie to Rails is a single
conditionally required file; it is not loaded outside Rails, and no Rails code is
pulled in. The details, including the one genuine restriction — workers must be
started through `Sneakers::Runner` — are in [docs/SETUP.md](docs/SETUP.md).

### Initializer

Optional. For example, a Rails application can disable the monitor locally:

```ruby
KicksLiveness.configure do |config|
  config.enabled = !Rails.env.local?
end
```

The full list: `logger` (defaults lazily to `Sneakers.logger`), `enabled`,
`tick` (10 s), `startup_grace_ticks` (6).
A non-positive `tick` raises `ArgumentError`: the monitor thread sleeps on it,
so a non-positive value is not a setting but a broken monitor.

### Environment variables

| Variable | Default | |
|---|---|---|
| `KICKS_LIVENESS_DIR` | `/opt/app/tmp/health` | marks directory, **must live on tmpfs** |
| `KICKS_LIVENESS_MAX_AGE` | `45` | seconds after which a mark is stale |
| `KICKS_LIVENESS_TICK` | `10` | interval between ticks |

`tick` is the one setting that appears in both places; the initializer wins over
the variable, and only the worker reads it either way.

**Two runners in one pod need two directories.** An application that runs both
`rake sneakers:run` and `rake sneakers:active_job` has two supervisors, each
numbering its forks from zero — so with the default `KICKS_LIVENESS_DIR` they
would overwrite each other's `expected` and `worker-0`, and the probe would
answer for whichever wrote last. In separate pods, which is the usual
arrangement, there is nothing to do: each gets its own `emptyDir`. In one pod,
give each runner its own `KICKS_LIVENESS_DIR`.

`dir` and `max_age` deliberately **cannot** be set in the initializer. The probe
is launched by the kubelet as a separate process, which does not — and cannot —
read the application's initializer. Were they settable in two places, a
mismatch between the worker and the probe would pass unnoticed.

Garbage in a value does not bring the worker down — it falls back to the default.
An empty string counts as unset: in a ConfigMap that is what you get by
declaring a key and leaving it blank. `max_age` and `tick` are durations, so
zero and negative values fall back too: they parse perfectly well, and a
negative `max_age` would make every mark stale on arrival.

## Manifest

```yaml
        startupProbe:
          exec:
            command: ["bundle", "exec", "kicks-liveness"]
          periodSeconds: 5
          timeoutSeconds: 5
          failureThreshold: 60
        livenessProbe:
          exec:
            command: ["bundle", "exec", "kicks-liveness"]
          periodSeconds: 30
          timeoutSeconds: 5
          failureThreshold: 3
      terminationGracePeriodSeconds: 60
```

The marks directory has to be on tmpfs:

```yaml
        volumeMounts:
          - mountPath: /opt/app/tmp
            name: app-tmp
      volumes:
        - name: app-tmp
          emptyDir:
            medium: Memory        # without this the mark lands on disk
```

The container needs a writable volume mounted at, or above,
`KICKS_LIVENESS_DIR`. The default mount at `/opt/app/tmp` covers
`/opt/app/tmp/health`, and the gem creates the `health` subdirectory itself.
Without this mount, a container using `readOnlyRootFilesystem: true` cannot
publish heartbeat files and never passes the startup probe.

Why it looks like this:

- **`bundle exec kicks-liveness` is the standard command**, and it works
  regardless of where Bundler installed the gems. There is a faster form —
  `ruby -e "require 'kicks_liveness/probe'"`, 52 ms against
  156 ms — but it needs the gems to be in `GEM_HOME`, and **setting
  `BUNDLE_PATH` at all moves them**, even to the directory `GEM_HOME` already
  points at. Check before you optimise:

  ```bash
  docker run --rm your-image bundle exec kicks-liveness
  docker run --rm your-image ruby -e "require 'kicks_liveness/probe'"
  ```

  Both should print `no .../expected` and exit 1. If the second raises
  `LoadError`, keep the standard command — at `periodSeconds: 30` it costs about
  0.005 of a core, against roughly 0.18 for a probe that boots the application.
  The trade-offs are in
  [docs/KUBERNETES.md](docs/KUBERNETES.md#where-your-image-puts-its-gems).

- **`startupProbe` is mandatory.** Startup and steady state have different time
  budgets, and one probe cannot serve both. While it runs, liveness is disabled
  and the container is not Ready. `failureThreshold: 60` buys 300 s, which is
  deliberately generous — measure a *freshly created* pod before trimming it, as
  a restarted container inherits a warm compile cache and a new pod does not:
  [measure the cold start](docs/KUBERNETES.md#measure-the-cold-start-not-the-restart).
- **It also protects rollouts — given `maxUnavailable: 0`.** Because the
  container is not Ready until the mark exists, a `RollingUpdate` that is not
  allowed to drop below full capacity cannot remove the old pod before the new
  one has subscribed. That is a property of the strategy as much as of the probe:
  with a non-zero `maxUnavailable`, or with `Recreate`, the old pod may go first
  and leave the queue uncovered.
- **`initialDelaySeconds` on liveness is unnecessary**; the startupProbe plays
  that role.
- Before a kill there is `max_age + periodSeconds × failureThreshold` = 45 + 90 =
  **135 s** of confirmed silence. Slow on purpose: a worker is not
  latency-critical, and a false restart costs more than two minutes of stalling.

## Required companion: an alert on consumers

The probe deliberately reports healthy while Bunny is reconnecting — otherwise a
broker hiccup would restart every replica at once. The price is that **broker
unavailability stops being visible automatically**. A pod can be consuming
nothing and look perfectly healthy.

So the probe needs an alert alongside it, and that alert should be in place
**before** the manifest is switched over:

```yaml
- alert: QueueWithoutConsumers
  expr: rabbitmq_detailed_queue_consumers{queue=~"myapp\..+", queue!~".*delayed_active_job.*"} == 0
  for: 5m

# Not optional: the expression above cannot fire when the series is gone.
- alert: QueueConsumerMetricMissing
  expr: absent_over_time(rabbitmq_detailed_queue_consumers{queue=~"myapp\..+"}[10m])
  for: 5m
```

Excluding the delayed queues is mandatory — they have no consumers by design, and
without the exclusion the alert fires permanently until someone silences it.
Match them as a **substring**: under ActiveJob the full name looks like
`myapp.active_job.myapp.delayed_active_job:60`, so an anchored pattern never
matches.

Two traps in getting that metric, both measured on RabbitMQ 3.13.7 rather than
recalled. The per-queue series is `rabbitmq_detailed_queue_consumers`, and it
only exists on `/metrics/detailed` **scraped with `family=queue_consumer_count`**
— bare, that endpoint serves no queue metrics at all, while plain `/metrics`
offers a same-sounding `rabbitmq_queue_consumers` that is a single label-less
cluster total, so a `{queue=~...}` matcher against it is quietly never true. And
the series **disappears** rather than going to zero when the queue is deleted or
the broker stops, which is why the second alert is there.
[docs/KUBERNETES.md](docs/KUBERNETES.md#getting-that-metric-at-all) has the
scrape config.

## What is checked

The mark is written only if **every** worker in the process has subscribed:

| State | Verdict |
|---|---|
| consumers in place, channel open | healthy |
| Bunny is recovering the connection | **healthy** — the broker heals itself |
| connection open, no consumers | unhealthy, a restart is the cure |
| not the whole set subscribed | unhealthy |

The expected consumer count comes from `config[:worker_classes]` — the same set
kicks itself builds its workers from. That way the queue list is never
duplicated and cannot drift from the configuration.

The files are named by supervisor slot rather than by PID: a dead fork is
respawned into the same slot and overwrites its own file. With a PID in the
name, SIGKILL would leave a stale file forever. With `workers > 1` the probe
requires every slot to be fresh.

## Limitations

The predicate is computed over the Bunny objects **in the process's memory** —
that is the whole point, but it has a boundary: it is exactly as truthful as
Bunny's own bookkeeping. The broker is never asked for its opinion.

**1. Consumer bookkeeping is updated on the worker's thread pool.** When the
broker cancels a consumer (on `consumer_timeout`, for example), it sends
`basic.cancel`, and Bunny removes the entry from its list — but it does so
through `@work_pool.submit`, that is, on the same pool that processes jobs
(`threads: 10` by default). Until a thread frees up, `any_consumers?` still
answers yes.

In practice this means: if **all** of the worker's threads are busy with stuck
jobs, the probe stays green even though the pod is consuming nothing. One stuck
job out of ten does not produce that effect.

**2. `recover_cancelled_consumers!` makes the probe blind to a cancelled
consumer.** `Bunny::Channel#recover_cancelled_consumers!` is an opt-in method
that neither Kicks nor Sneakers enables. With it on, Bunny re-subscribes the
consumer itself on `basic.cancel` and **keeps** the entry in its list — so the
"consumer was cancelled" case stops being detectable at all. Do not enable it
together with this probe.

**3. Broker unavailability is invisible by design** — see [the alert on
consumers](#required-companion-an-alert-on-consumers) above.

All three limitations point the same way: an alert on consumers, watching the
broker **from the outside**, is not a nice-to-have but part of the design. It
catches exactly what an in-memory predicate cannot see.

## Verifying on a live pod

```bash
kubectl exec deploy/myapp -- ls -l /opt/app/tmp/health/
kubectl exec deploy/myapp -- sh -c 'bundle exec kicks-liveness; echo "exit=$?"'
kubectl logs deploy/myapp | grep liveness
```

Check the **negative** path too — otherwise a working probe is
indistinguishable from an always-green one:

```bash
kubectl exec deploy/myapp -- sh -c 'touch -d "2 minutes ago" /opt/app/tmp/health/worker-0; bundle exec kicks-liveness; echo "exit=$?"'
```

Expect `worker-0 stale 120s > 45s` and `exit=1`. One tick later the mark repairs
itself.

## Logs

Events are logged, not the pulse: the pulse lives in the mark's mtime.

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

ERROR is reserved for genuine failure: a logger usually comes up with
`LOG_LEVEL` defaulting to `error`, so anything that matters must survive that
filter, while an ordinary deploy must not make noise. That is also why shutdown
is an event of its own: the workers unsubscribe while the thread pool drains,
and judged by the consumer count alone a normal deploy would look exactly like
a fault. From the moment shutdown begins the probe keeps the mark fresh
instead, so a slow drain gets the full `terminationGracePeriodSeconds`.
