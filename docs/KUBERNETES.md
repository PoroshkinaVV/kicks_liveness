# Running under Kubernetes

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

The marks directory must be on tmpfs:

```yaml
        volumeMounts:
          - mountPath: /opt/app/tmp
            name: app-tmp
      volumes:
        - name: app-tmp
          emptyDir:
            medium: Memory        # without this the mark lands on a disk
```

The container must have a writable volume mounted at, or above,
`KICKS_LIVENESS_DIR`. With the default value, mounting `/opt/app/tmp` covers
`/opt/app/tmp/health`, and the gem creates the `health` subdirectory itself.

This mount is required when `readOnlyRootFilesystem: true`. Without it, the
worker cannot create the heartbeat files, the startup probe never succeeds,
and Kubernetes eventually restarts the container. If you change
`KICKS_LIVENESS_DIR`, make sure that `volumeMount.mountPath` covers the new
location.

Without `medium: Memory` an `emptyDir` is backed by the node's disk, and the
probe starts depending on the disk again — which is one of the things it exists
to avoid.

## Why the command looks like that

**`bundle exec kicks-liveness` is the standard command.** It works regardless
of where Bundler installed the gems, because Bundler is the thing that knows
where it put them. It is what you should reach for unless you have measured a
reason not to.

There is a faster form, and the difference is real but small — measured in a
container on the fixture in [VERIFYING.md](VERIFYING.md):

| | per invocation | works when |
|---|---|---|
| `bundle exec kicks-liveness` | 156 ms | always |
| `ruby -e "require 'kicks_liveness/probe'"` | 52 ms | the gems are in `GEM_HOME` |
| `ruby --disable-gems -I <dir> -e "..."` | ~10 ms | you add a line to the Dockerfile |

Those three were timed inside a container, twenty invocations each, on the
fixture in [VERIFYING.md](VERIFYING.md). Absolute numbers move with the machine
— [DESIGN.md](DESIGN.md#why-the-heartbeat-file-has-no-require-of-its-own) breaks
the same commands down on a host and gets smaller ones. The ratios are what to
plan against.

Keep the second and third in proportion. At `periodSeconds: 30`, the standard
command costs `0.156 / 30 ≈ 0.005` of a core and the fastest one saves about
`0.005`. Against a probe that boots the application — 4 s in the median and 27 s
in the tail, which is what this gem replaces — all three have already won by two
orders of magnitude. Reach for the optimised forms when you are on a very short
period or a very tight CPU request, not by default.

The bare executable, `kicks-liveness` without `bundle exec`, is a third thing
again: it depends on the gem's `bin` directory being on `PATH`, which it is not
in an image that moves its gems. Use it from `kubectl exec` by hand if it works
there; do not put it in a manifest.

**`startupProbe` is not optional.** Startup and steady state have different time
budgets, and one probe cannot serve both. While the startup probe runs, liveness
is disabled and the container is not Ready.

That last part also protects a rollout, **on the condition that the strategy is
not allowed to drop below full capacity** — `RollingUpdate` with
`maxUnavailable: 0` (which is what `25%` rounds down to at one replica). Then
Kubernetes may not remove the old pod until the new one is Ready, and Ready here
means the mark is on tmpfs, which means the consumers are subscribed. State the
condition when you rely on it: with a non-zero `maxUnavailable`, or with a
`Recreate` strategy, the old pod can be gone while the new one is still booting,
and nothing is consuming in between. [VERIFYING.md](VERIFYING.md#9-a-rolling-deploy-keeps-the-queue-covered)
measures the covered case.

**`initialDelaySeconds` on the liveness probe is unnecessary.** With a
`startupProbe` present, liveness does not run until the startup probe succeeds,
so the delay would have no effect.

`kicks-liveness` and `require 'kicks_liveness/probe'` do the same thing; the
difference is only in how the file is found. Run through `bundle exec`, the
executable is found regardless of `BUNDLE_PATH`, which is why it is the standard
command. Run bare, it depends on the gem's `bin` directory being on `PATH`,
which is not something to rely on in a manifest.

### Where your image puts its gems

Before replacing the standard command with plain Ruby, run this against your
image. One line, no cluster needed:

```bash
docker run --rm your-image ruby -e "require 'kicks_liveness/probe'"
```

A line like `no /opt/app/tmp/health/expected: worker has not started yet` and
exit 1 means the plain command works — the probe found itself and correctly
reported that no worker is running. A `LoadError` means it does not: keep
`bundle exec kicks-liveness`, or use the explicit-path optimisation below. Do
not put the plain command in a manifest without this check: its failure mode is
a pod that never passes `startupProbe` and lands in `CrashLoopBackOff`.

What decides it is whether Bundler installed into `GEM_HOME` or somewhere of
its own. **Setting `BUNDLE_PATH` at all is enough to move them**, including
setting it to the very directory `GEM_HOME` already points at — a common
Dockerfile idiom that looks like a no-op and is not:

```dockerfile
ENV BUNDLE_PATH=/usr/local/bundle     # GEM_HOME is already /usr/local/bundle
```

```
/usr/local/bundle/gems/                     <- where GEM_HOME looks
/usr/local/bundle/ruby/3.4.0/gems/          <- where that Dockerfile puts them
```

Plain `ruby -e` then raises `LoadError`, and so does the `kicks-liveness`
executable, because the binstub directory Bundler used is not on `PATH`
either. `bundle config set path vendor/bundle` does the same thing more
visibly.

#### If your image moves its gems

Three ways out, in the order worth considering them.

**Keep the standard command.** `bundle exec kicks-liveness` already works. This
is not a consolation prize: at `periodSeconds: 30` it costs about
`0.156 / 30 ≈ 0.005` of a core, against roughly 0.18 for a probe that boots the
application.

**Stop moving the gems.** Dropping `BUNDLE_PATH` from the Dockerfile and letting
the base image's `GEM_HOME` stand restores the fast command with no
probe-specific machinery at all. That is a decision about how your image is
built rather than about this gem, and it may well be the right one for other
reasons.

**Name the path explicitly.** Pass the gem's `lib` directory with `-I`; once you
are naming a path anyway, add `--disable-gems`, which costs nothing extra and
makes the probe faster again. This buys the fastest command in exchange for a
line in the Dockerfile — the next section is about writing that line so it does
not go stale on the following gem upgrade.

### Skipping RubyGems entirely

`--disable-gems` switches off the RubyGems library: gem activation, gem path
resolution, the `Gem` constant. It does **not** switch off `require`, which is a
plain `$LOAD_PATH` lookup — so `-I <dir>` is all the probe needs in order to be
found.

And it needs nothing beyond that, because requiring `kicks_liveness/probe` loads
exactly two files: the probe entry point and the heartbeat. The heartbeat file
runs no `require` on the path the probe takes — the one it contains,
`fileutils`, is lazy and sits in a branch only the worker reaches — and it
refers to nothing else in the gem, so there is no gem to activate: no gem's code
is involved. This is the reason that file is kept dependency-free.

The worker side is the opposite and needs RubyGems, because it needs `kicks` or
`sneakers`. That is fine: the worker is an ordinary application process started
under Bundler, and nobody launches it with `--disable-gems`.

So the probe can run on a bare interpreter:

| | per invocation |
|---|---|
| `ruby -e "require 'kicks_liveness/probe'"` | 43 ms |
| `ruby --disable-gems -I <gem lib> -e "require 'kicks_liveness/probe'"` | 10.5 ms |

The catch is the path. A gem's `lib` directory carries its version:

```
/usr/local/bundle/gems/kicks_liveness-0.1.0/lib
```

Put that in a manifest and the manifest becomes wrong on the next gem upgrade —
silently, and the symptom is `CrashLoopBackOff`, which is exactly the class of
failure this gem exists to remove. So do not hardcode it there.

Instead resolve it once at image build time and expose a stable path:

```dockerfile
RUN ln -s "$(bundle info kicks_liveness --path)/lib" /opt/kicks-liveness
```

**Ask bundler, not RubyGems.** It is tempting to resolve the path with
`ruby -e 'Gem::Specification.find_by_name("kicks_liveness")...'`, but in the
image this section is about, that command fails the same way the probe does:
`find_by_name` searches `GEM_HOME`, the gem is under `vendor/bundle`, and you
get `Gem::MissingSpecError` at build time instead of a symlink. Bundler is the
thing that knows where it put the gem, so bundler is what has to be asked.
(`bundle show kicks_liveness` prints the same path on older bundlers.)

```yaml
          exec:
            command: ["ruby", "--disable-gems", "-I", "/opt/kicks-liveness",
                      "-e", "require 'kicks_liveness/probe'"]
```

Now the version lives in the Dockerfile, which is rebuilt when the gem changes,
and the manifest stays stable across upgrades.

**Is it worth it?** Usually not. At `periodSeconds: 30`, saving 33 ms per
invocation is `0.033 / 30 ≈ 0.001` of a core — against roughly 0.18 of a core
for a probe that boots the application. Both options have already won by two
orders of magnitude, and the simpler command has one less thing to keep in sync.
Reach for `--disable-gems` when you are on a very short period, a very tight CPU
request, or when you have to pass `-I` anyway.

## The arithmetic

**Startup budget** = `periodSeconds × failureThreshold` = 5 × 60 = **300 s**.
There is no `initialDelaySeconds`: the startup probe fails harmlessly until the
consumers are up, so a delay would only postpone the first check.

That number is deliberately generous, and it is the one value here you should
not trim on taste. The two failure modes are not symmetric: an oversized budget
only means a genuinely broken container is restarted later, which for a
background worker costs nothing, while an undersized one means the container
never starts at all — and the symptom, a pod that keeps being killed, reads
exactly like a broken probe.

### Measure the cold start, not the restart

A pod that has been running for a week is the wrong thing to measure. The marks
directory is an `emptyDir`, and applications commonly put a bootsnap or
similar compile cache under the same mount — so a **newly created pod** starts
with that cache empty and recompiles it during `run_initializers`, while a
**restarted container** in an existing pod inherits a warm one.

A worked example, from a Rails worker with five consumers measured on two
environments. Cold, on a fast local machine: **60–61 s** from container start
to the first healthy mark. The same application on slower infrastructure, under
a 75 s budget: containers killed at **74–76 s**, then coming up on the retry
because the second attempt found the cache warm.

Read that pair carefully, because it is the trap rather than the number. The
budget was not obviously wrong — it exceeded every warm measurement and most
cold ones. It was simply sitting on top of the distribution, so the failure
arrived as an intermittently flapping pod that healed itself on restart, which
is about the hardest symptom there is to attribute to a probe setting. A budget
chosen from the median is a budget that fails on the tail; and the tail moves
with the machine, so it is not something you can compute once from someone
else's numbers.

So: create a fresh pod, time it from container start to the first
`[liveness] slot 0: healthy`, repeat it enough times to see the tail rather
than the median, and only then consider lowering `failureThreshold`. Kubernetes
documents `startupProbe` for exactly this — slow-starting containers, sized
against the worst observed initialisation, not the usual one.

The better fix is outside this gem: warm the cache at image build time (point
`BOOTSNAP_CACHE_DIR` somewhere outside the mounted volume and run
`bootsnap precompile`). Then cold starts stop existing, every pod starts
faster, and the threshold can honestly come down.

**Steady state** = `max_age` + `periodSeconds × failureThreshold` = 45 + 90 =
**135 s** of confirmed silence before the container is killed. That is slow on
purpose: a background worker is not latency-critical, and a false restart costs
more than two minutes of a genuinely hung pod. Note that `max_age` is part of
this sum — the mark has to go stale before a probe can fail on it.

**Grace period** must cover the slowest orderly shutdown. Cancelling a consumer
is a round trip to the broker, and Bunny applies its own timeout to it; with
several consumers per worker these add up. If the grace period is shorter than
that, the container is SIGKILLed mid-shutdown and in-flight messages are
redelivered.

## Environment variables

| Variable | Default | Purpose | Invalid or blank value |
|---|---|---|---|
| `KICKS_LIVENESS_DIR` | `/opt/app/tmp/health` | marks directory, **must be on tmpfs** | uses the default |
| `KICKS_LIVENESS_MAX_AGE` | `45` | seconds after which a mark is stale | uses the default |
| `KICKS_LIVENESS_TICK` | `10` | interval between ticks | uses the default, then the safety fallback below if needed |

Keep `tick` well below `max_age`. A tick longer than half of `max_age` leaves no
room for a single missed write, and a tick longer than `max_age` guarantees a
restart loop. If environment values produce `tick >= max_age`, the worker writes
a WARN to stderr and uses the default tick when that is safe, or half of
`max_age` otherwise. An initializer value with the same mismatch raises
`ArgumentError`. The half-threshold remains the recommended operational margin.

`KICKS_LIVENESS_DIR` is also what separates two runners that share a pod. An
application running both `rake sneakers:run` and `rake sneakers:active_job` has
two supervisors, and each numbers its forks from zero — so on the default path
they would overwrite each other's `expected` and `worker-0`, and the probe would
report whichever wrote last. Deployed as two pods, which is the usual shape,
each already has its own `emptyDir` and there is nothing to do. In one pod, give
each runner its own directory:

```yaml
        env:
          - name: KICKS_LIVENESS_DIR
            value: /opt/app/tmp/health/active_job
```

Both still have to sit under the tmpfs mount, and each container needs its own
probe command pointed at its own directory — the probe reads
`KICKS_LIVENESS_DIR` from its own environment, which the kubelet takes from the
container it runs in.

An empty string counts as unset, which is what a ConfigMap gives you when a key
is declared and left blank.

## Verifying on a live pod

```bash
kubectl exec deploy/myapp -- ls -l /opt/app/tmp/health/
kubectl exec deploy/myapp -- sh -c 'bundle exec kicks-liveness; echo "exit=$?"'
kubectl logs deploy/myapp | grep liveness
```

Then verify the **negative** path. This is not optional: without it you cannot
distinguish a working probe from one that is green unconditionally, and a
permanently green liveness probe is worse than no probe at all, because it looks
like coverage.

```bash
kubectl exec deploy/myapp -- sh -c \
  'touch -d "2 minutes ago" /opt/app/tmp/health/worker-0; bundle exec kicks-liveness; echo "exit=$?"'
```

Expected output is `worker-0 stale 120s > 45s` and `exit=1`. One tick later the
mark repairs itself, so the test is safe to run in production.

The probe prints its reason to stdout, and the kubelet surfaces that text in the
`Unhealthy` event. This matters more than it sounds: an exec probe has its own
stdout, which does **not** appear in the pod's logs, so the event is the only
place the reason is visible. `kubectl describe pod` is where you read it.

That recipe proves the probe reacts. It does not prove that the **kubelet**
reacts, because the mark repairs itself on the next tick, long before
`failureThreshold` is reached — and the failures that would prove it are not
ones to cause on a pod you care about. [VERIFYING.md](VERIFYING.md) causes
them on a disposable local cluster instead: a deleted queue, a killed broker,
wrong credentials, a rolling deploy.

## Required companion: an alert on consumers

The probe deliberately reports healthy while Bunny is reconnecting, so that a
broker hiccup does not restart every replica at once. The price is that **broker
unavailability stops being visible automatically**: a pod can consume nothing and
still look perfectly healthy.

So the probe needs an external alert, and that alert should exist **before** you
switch the manifest over:

```yaml
- alert: QueueWithoutConsumers
  expr: rabbitmq_detailed_queue_consumers{queue=~"myapp\..+", queue!~".*delayed_active_job.*"} == 0
  for: 5m

# Not optional: the expression above cannot fire when the series is gone.
- alert: QueueConsumerMetricMissing
  expr: absent_over_time(rabbitmq_detailed_queue_consumers{queue=~"myapp\..+"}[10m])
  for: 5m
```

Exclude delayed queues — they have no consumers by design, and without the
exclusion the alert fires permanently until someone silences it. Match them as a
**substring**: with ActiveJob the full name looks like
`myapp.active_job.myapp.delayed_active_job:60`, where the ActiveJob prefix is
prepended and the delay is appended after a colon, so an anchored pattern will
never match.

### Getting that metric at all

Three things about the `rabbitmq_prometheus` plugin, measured on 3.13.7 rather
than taken from memory:

**The name is `rabbitmq_detailed_queue_consumers`, not
`rabbitmq_queue_consumers`.** The two are different metrics. On the ordinary
`/metrics` endpoint, `rabbitmq_queue_consumers` exists but carries **no labels
at all** — it is one cluster-wide total:

```
rabbitmq_queue_consumers 4
```

A `{queue=~...}` matcher against that selects nothing, so an alert written on it
is silently never true.

**`/metrics/detailed` returns nothing unless you ask for a family.** Scraped
bare it serves only telemetry and build info. The scrape config has to name what
it wants:

```yaml
- job_name: rabbitmq
  metrics_path: /metrics/detailed
  params:
    family: [queue_consumer_count]
```

Then the series arrives with the labels the alert needs — including a `vhost`
label, which is worth adding to the matcher if more than one vhost is in play:

```
rabbitmq_detailed_queue_consumers{vhost="/",queue="myapp.orders"} 2
```

**A series that disappears is not a series that is zero.** This is why the
second alert is not decoration. `rabbitmq_detailed_queue_consumers` is exported
per existing queue, so it vanishes — rather than dropping to 0 — when the queue
is deleted, when the broker goes down, and when the exporter itself stops. A
deleted queue is exactly the failure this probe is built to catch: the consumer
goes away, the pod is restarted, and the `== 0` alert stays quiet throughout
because there is nothing left to compare. `absent_over_time` covers that; so
does an `up == 0` alert on the scrape job, and you want both if the broker and
the exporter can fail independently.
