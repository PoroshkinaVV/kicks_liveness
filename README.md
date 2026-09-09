# kicks_liveness

[![Gem Version](https://badge.fury.io/rb/kicks_liveness.svg)](https://rubygems.org/gems/kicks_liveness)
[![CI](https://github.com/PoroshkinaVV/kicks_liveness/actions/workflows/ci.yml/badge.svg)](https://github.com/PoroshkinaVV/kicks_liveness/actions/workflows/ci.yml)

![kicks_liveness — Kicks and Sneakers worker health](https://raw.githubusercontent.com/PoroshkinaVV/kicks_liveness/main/assets/github-social-preview.png)

**Know when a [Kicks](https://github.com/ruby-amqp/kicks) or
[Sneakers](https://github.com/jondot/sneakers) worker is stuck — without booting
Rails or querying RabbitMQ from the probe.**

The worker checks its own Bunny consumers and publishes a heartbeat to tmpfs.
The probe only reads that heartbeat. No application boot, no network call, and
no healthy replica hiding a stalled one.

## Install: one line in Rails

```ruby
# Gemfile — keep exactly one of kicks or sneakers alongside it
gem 'kicks_liveness'
```

```bash
bundle install
```

In Rails, that is all the application-side setup: the Railtie installs the hooks
automatically. Without Rails, add two lines before `Sneakers::Runner` starts:

```ruby
require 'kicks_liveness'
KicksLiveness.install!
```

Requirements: Ruby >= 3.1 and exactly one of `kicks` >= 3.0 or `sneakers` >=
2.11. CI pins both floors and tracks the current release of both worker lines.
Do not put both worker gems in the same bundle: both provide
`lib/sneakers.rb`, so `install!` rejects that ambiguous process.
Framework-specific examples are in [Setup](docs/SETUP.md).

## Why replace the usual probe?

The common alternative is a rake task that boots the application and asks
RabbitMQ for `consumer_count`.

| | Rails + `consumer_count` probe | `kicks_liveness` |
|---|---|---|
| Code started on every probe | Rails and the application | Ruby, Bundler, and the probe files |
| Network call | RabbitMQ request | none |
| Health scope | a queue shared by every replica | this worker process |
| Decision path | application files plus RabbitMQ | process memory plus a tmpfs heartbeat |
| Measured invocation | **2.7 s of CPU** on a real service | **156 ms** in the fixture container |
| Continuous cost in the measured setups | **~0.18 core** at a 15 s period | **~0.005 core** at a 30 s period |
| During Bunny network recovery | may restart every replica together | stays healthy while Bunny reconnects |

Absolute timings depend on the image and hardware; the two columns are measured
examples, not a same-host microbenchmark. The calculation and faster 52 ms and
~10 ms probe forms are documented in [Running under Kubernetes](docs/KUBERNETES.md#why-the-command-looks-like-that).

Every 10 seconds by default, each worker verifies that all expected consumers
are subscribed and touches its own mark. `bundle exec kicks-liveness` exits 0
only when every expected worker mark is present and fresh.

## Kubernetes

Use a startup probe for the boot budget and a liveness probe for steady state:

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

Put the heartbeat directory on tmpfs:

```yaml
        volumeMounts:
          - mountPath: /opt/app/tmp
            name: app-tmp
      volumes:
        - name: app-tmp
          emptyDir:
            medium: Memory
```

The default heartbeat directory is `/opt/app/tmp/health`; the gem creates the
`health` subdirectory. The mount is also required with
`readOnlyRootFilesystem: true`.

With the values above, confirmed silence lasts at most `45 + 30 × 3 = 135 s`
before Kubernetes kills the container. Size the startup budget from fresh-pod
measurements, not warm restarts. See [the full manifest and budget
arithmetic](docs/KUBERNETES.md).

## Configuration

Everything is optional. Application settings belong in an initializer:

```ruby
KicksLiveness.configure do |config|
  config.enabled = !Rails.env.local?
end
```

| Ruby setting | Default | Purpose | Valid values |
|---|---|---|---|
| `logger` | `Sneakers.logger`, resolved lazily | transition and error logs | logger-compatible object |
| `enabled` | `true` | start the monitor thread | `true` or `false` |
| `tick` | `10` | seconds between worker checks | positive number smaller than `max_age` |
| `startup_grace_ticks` | `6` | unhealthy startup ticks before one ERROR | positive integer |

The separate probe cannot read an application initializer. The shared path and
freshness threshold therefore come from the environment; `tick` may use the
environment too:

| Environment variable | Default | Purpose | Invalid or blank value |
|---|---|---|---|
| `KICKS_LIVENESS_DIR` | `/opt/app/tmp/health` | heartbeat directory; must be on tmpfs | uses the default |
| `KICKS_LIVENESS_MAX_AGE` | `45` | seconds before a mark is stale | uses the default |
| `KICKS_LIVENESS_TICK` | `10` | seconds between worker checks | uses the default, then the safety fallback below if needed |

If the effective environment tick is not smaller than `max_age`, the worker
writes a WARN to stderr and uses `10` seconds when that is safe, or half of
`max_age` otherwise. This keeps a ConfigMap mistake from stopping the worker
while guaranteeing that a healthy heartbeat cannot become stale between
ordinary ticks.

An initializer value for `tick` wins over `KICKS_LIVENESS_TICK`. `dir` and
`max_age` deliberately have no initializer setters: allowing two configuration
sources could make the worker and probe silently disagree.

If two runners share one pod — for example `sneakers:run` and
`sneakers:active_job` — give each a different `KICKS_LIVENESS_DIR`. Separate
pods already have separate `emptyDir` volumes.

## What is healthy?

| Worker state | Probe verdict | Reason |
|---|---|---|
| every consumer subscribed, channel open | healthy | the process can consume work |
| Bunny recovering its connection | **healthy** | Bunny reconnects itself; restarting adds a reconnect storm |
| connection open, no consumers | unhealthy | a restart is the cure |
| only part of the expected worker set subscribed | unhealthy | one healthy worker must not hide a missing one |

The check reads Bunny objects already in the worker's memory. It never asks the
broker for its view.

## Operational contract

- Start workers through `Sneakers::Runner`; that is where the monitor hook is
  attached. `rake sneakers:run` already does this.
- Keep the `startupProbe`. With `RollingUpdate` and `maxUnavailable: 0`, it also
  keeps the old pod until the new worker has subscribed.
- Add an external alert for queues with zero or missing consumers **before**
  switching probes. Broker unavailability is invisible here by design; the
  exact Prometheus rules are in [Running under Kubernetes](docs/KUBERNETES.md#required-companion-an-alert-on-consumers).
- Restart the runner after changing its process count; changing `workers` at
  runtime is not supported.

The other boundaries — blocked worker pools, cancelled-consumer recovery, and
per-pod versus per-queue scope — are collected in [Limitations](docs/LIMITATIONS.md).

## Verify it

```bash
kubectl exec deploy/myapp -- ls -l /opt/app/tmp/health/
kubectl exec deploy/myapp -- sh -c 'bundle exec kicks-liveness; echo "exit=$?"'
```

The healthy result is `N process(es) healthy` with exit code 0. Also test the
negative path before rollout; the commands and expected output are in
[Verifying the probe](docs/VERIFYING.md#2-a-stale-mark).

## Documentation

| Guide | Use it for |
|---|---|
| [Setup](docs/SETUP.md) | Rails, Sinatra, Hanami, Roda, standalone runners, and hook verification |
| [Design](docs/DESIGN.md) | health predicate, heartbeat files, hooks, configuration choices, and measurements |
| [Running under Kubernetes](docs/KUBERNETES.md) | full manifest, CPU/startup budgets, alerts, and live-pod verification |
| [Limitations](docs/LIMITATIONS.md) | cases the in-memory predicate intentionally cannot cover |
| [Verification scenarios](docs/VERIFYING.md) | ten deliberately induced failures and their observed outcomes |

## Contributing

Setup, running the suite against both worker gems, and the release procedure are
in [CONTRIBUTING.md](https://github.com/PoroshkinaVV/kicks_liveness/blob/main/CONTRIBUTING.md).
