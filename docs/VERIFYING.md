# Verifying the probe against a real broker

[KUBERNETES.md](KUBERNETES.md#verifying-on-a-live-pod) shows how to confirm the
probe on a pod you already run. This document is the other half: a disposable
local cluster where the **failures themselves** can be caused on purpose, so
that every claim the gem makes is watched rather than reasoned about.

Two of those claims cannot be checked any other way, because both are properties
of Bunny rather than of this gem:

- that `channel.any_consumers?` turns false when the broker takes a consumer
  away, which is what the probe fails on;
- that `recovering_from_network_failure?` stays true for the whole of a broker
  outage, which is what keeps a hiccup from restarting every replica.

And one is a property of the kubelet: that a red probe actually restarts the
container. The `touch -d` recipe in KUBERNETES.md deliberately repairs itself
within one tick, so on its own it never reaches `failureThreshold`.

The fixture lives in `spec/integration/` in the repository. It is not part of the
published gem, and it is not part of `rake` — nothing under it is a `_spec.rb`
file, so `rspec` does not collect it.

## What you need

A local single-node cluster. Docker Desktop's built-in Kubernetes is the
cheapest option, because an image built locally is visible to the cluster
immediately, with no registry and no load step — `imagePullPolicy: Never` is all
it takes.

```bash
spec/integration/verify.sh build   # image, into the engine the cluster uses
spec/integration/verify.sh status  # print and verify the exact target
spec/integration/verify.sh up      # namespace, broker, worker
spec/integration/verify.sh down    # deletes the namespace
```

Every `kubectl` call names its context and namespace explicitly, so the script
never falls back to `current-context`. It will still operate on whichever target
you configure: run `status` and inspect both values before `up` or `down`. The
script labels namespaces it creates and refuses to apply to or delete an
existing namespace without that ownership label.

The default image uses Kicks. Build it with Sneakers instead without editing the
fixture:

```bash
AMQP_WORKER_GEM=sneakers spec/integration/verify.sh build
```

Three things that cost time if you meet them the hard way:

- **Build into the right engine.** If the machine also runs OrbStack, Colima or
  Rancher Desktop, the default docker context is not the one Docker Desktop's
  Kubernetes reads images from, and the pod fails with `ErrImageNeverPull`. The
  script passes `--context desktop-linux` for this reason.
- **A `path:` gem is not in `GEM_HOME`.** Bundler adds it to the load path and
  nothing else. The standard command, `bundle exec kicks-liveness`, does not care
  — Bundler put it there and Bundler finds it. The **optimised** command,
  plain `ruby -e` with no Bundler, raises `LoadError`. It is one instance of
  [where your image puts its gems](KUBERNETES.md#where-your-image-puts-its-gems),
  and worth meeting here rather than in a rollout. The fixture image therefore
  also `gem install`s the gem it builds, so that both commands are exercised the
  way a published gem would be.
- **`ruby:*-slim` has no compiler.** `bunny` pulls `sorted_set`, which pulls
  `rbtree`, which is a native extension.

## The scenarios

Each one is an action and a single observable value. The values below are the
ones actually recorded on Kubernetes v1.25 with kicks 3.4.0, bunny 3.3.0 and
ruby 3.4, using the probe settings printed in KUBERNETES.md
(`tick` 10 s, `max_age` 45 s, liveness `periodSeconds` 30 × `failureThreshold` 3).

The same scenarios have since been replayed against a production Rails
application — five consumers, two runners, one of them an ActiveJob adapter
whose worker set is a callable registry rather than an array — on the same kind
of throwaway cluster. Every outcome matched the fixture's, which is the point of
keeping the fixture small: if a two-queue toy and a real application disagree,
the disagreement is the finding.

The **startup** budget never binds anything here, so no number below depends on
it: this fixture subscribes in under a second, where a real application takes
tens of seconds. That is precisely why the cold-start measurement in
[KUBERNETES.md](KUBERNETES.md#measure-the-cold-start-not-the-restart) has to be
made against your own application — a fixture cannot do it for you.

### 1. It comes up

```bash
spec/integration/verify.sh logs | grep liveness
spec/integration/verify.sh marks
spec/integration/verify.sh probe
```

```
INFO: [liveness] slot 0: started: dir=/opt/app/tmp/health max_age=45s tick=10s processes=1 consumers=2
INFO: [liveness] slot 0: waiting for 2 consumers
INFO: [liveness] slot 0: healthy          # one tick later
expected  generation  worker-0            # in the marks directory
1 process(es) healthy                     # probe, exit 0
```

The hooks fired inside a real ServerEngine fork, which no double can show. On a
fresh fixture the first attempt also prints `started:`. Do not use that line as
the sole proof after a same-pod container restart: an inherited unhealthy-run
counter deliberately suppresses repeated start lines, as described in
[LIMITATIONS.md](LIMITATIONS.md#a-respawn-loop-is-reported-once-per-grace-window-not-once-per-respawn).

### 2. A stale mark

The recipe from KUBERNETES.md. Proves the probe's threshold and the
self-repair, and nothing else — the mark is fixed on the next tick, well inside
`failureThreshold`, so the container is never killed.

Worth running through **both** commands here, since this is the one scenario
where the probe is supposed to answer `1`. `spec/integration/verify.sh probe`
does exactly that: the standard `bundle exec kicks-liveness` and the optimised
`ruby -e`, which in this image are both available and must agree.

```
worker-0 stale 120s > 45s   # exit 1
1 process(es) healthy       # exit 0, twelve seconds later
```

### 3. The broker takes the consumer away

The one that matters. Delete a queue the worker consumes from:

```bash
kubectl exec deploy/rabbitmq -- rabbitmqctl delete_queue kicks_liveness.alpha
```

Observed, from the moment of deletion:

| after the deletion | what |
|---|---|
| 9 s | `ERROR: [liveness] slot 0: became unhealthy (expected 2 consumers)` |
| 59 s | `ERROR: [liveness] slot 0: not healthy 60s, expected 2 consumers` |
| 61 s | first kubelet failure: `Liveness probe failed: worker-0 stale 69s > 45s` |
| 91 s, 121 s | the second and third, `stale 99s` and `stale 129s` |
| 132 s | `Killing: Container worker failed liveness probe, will be restarted` |

The two clocks in that table are different, which is worth reading carefully
if you are checking the arithmetic. The left column counts from the deletion.
The `stale Ns` in the probe's own text is the age of the mark, and the mark
stopped being refreshed one tick *before* the transition was logged — the tick
that found the process unhealthy is also the first one that did not touch the
file. So the probe's number runs about eight seconds ahead of the left column,
and the kill lands at `max_age + periodSeconds × failureThreshold` counted
from the last refresh, not from the deletion.

So `any_consumers?` does turn false, the transition is reported within one tick,
and the pod is restarted after `max_age + periodSeconds × failureThreshold`
— 132 s against the 135 s the arithmetic in KUBERNETES.md predicts. The worker
re-declares the queue on boot, so the pod recovers by itself.

Note where the probe's own text appears: in the kubelet's `Unhealthy` event,
not in the pod log. An exec probe's stdout goes nowhere else, which is why
`kubectl describe pod` is the place to read it.

### 4. The broker dies

```bash
kubectl delete pod -l app=rabbitmq --grace-period=0 --force
```

The pod must **not** restart. "It survived" is not enough on its own — a broker
that never actually went away would look the same — so check the log for
Bunny's own account of the outage:

```
WARN: Recovering from connection.close (CONNECTION_FORCED - broker forced connection closure with reason 'shutdown')
WARN: Will recover from a network failure (no retry limit)...
WARN: Could not establish TCP connection to rabbitmq:5672 ... TCP connection failed
WARN: Reconnecting in 5.0 seconds
```

Against that: `restartCount` stayed 0, the probe exited 0 at every check, and
no `became unhealthy` was logged. Bunny's topology recovery brought both
consumers back on its own.

### 5. The broker stays dead

`kubectl scale deploy/rabbitmq --replicas=0`, then wait. Observed over 319 s
— seven times `max_age`, more than twice the 135 s steady-state budget — the
mark's age never exceeded 9 s and `restartCount` stayed 0. The monitor kept
writing, because `recovering_from_network_failure?` never stops being true:
Bunny has no retry limit, which its own log line above says out loud.

This is
[Broker unavailability is invisible by design](LIMITATIONS.md#broker-unavailability-is-invisible-by-design),
seen rather than deduced. It is the reason the
[consumer alert](KUBERNETES.md#required-companion-an-alert-on-consumers) is part
of the design and not a suggestion.

Scaling the broker back up: the worker resumed consuming **in the same
container**, no restart.

### 6. An ordinary deploy

`kubectl delete pod` on the worker, with the log followed. Not one ERROR line.
Bunny cancels each consumer and the process exits.

If the shutdown finishes inside a single tick — an idle thread pool cancels
quickly — the monitor never gets to run again, so
`shutting down: consumers are no longer checked` may not appear at all. The
absence of ERROR is the observable, not the presence of that line.

### 7. Bad broker credentials

Point `AMQP_URL` at a wrong password. The fork cannot subscribe, so the
supervisor respawns it every `start_worker_delay`, forever. Over 120 s:

| | lines |
|---|---|
| fork starts | 426 |
| `started: dir=... consumers=2` | 1 |
| `waiting for 2 consumers` | 1 |
| liveness ERROR | 2 |

```
INFO:  [liveness] slot 0: started: dir=/opt/app/tmp/health max_age=45s tick=10s processes=1 consumers=2
INFO:  [liveness] slot 0: waiting for 2 consumers
ERROR: [liveness] slot 0: not healthy 60s over 224 starts, expected 2 consumers
ERROR: [liveness] slot 0: not healthy 60s over 426 starts, expected 2 consumers
```

Four lines from the gem across 426 respawns: the first incarnation announces
itself and reports waiting, every one after that is silent, and the escalation
speaks once per grace window carrying the number of starts, which is the
diagnosis. This is the behaviour
[the respawn section](LIMITATIONS.md#a-respawn-loop-is-reported-once-per-grace-window-not-once-per-respawn)
describes, against a real storm rather than a simulated one.

Worth knowing what the pod log looks like anyway: 27 000 lines in those same
120 s, an authentication error and a full backtrace printed by the worker gem on
every respawn. The gem's four lines are in there — `grep liveness` is how you
find them.

### 8. More than one fork

`WORKER_COUNT=2` needs no rebuild; the rake task turns it into
`config[:workers]`.

```
INFO: [liveness] slot 0: started: ... processes=2 consumers=2
INFO: [liveness] slot 1: started: ... processes=2 consumers=2
expected  generation  worker-0  worker-1  # expected contains "2"
2 process(es) healthy                     # exit 0
worker-1 stale 120s > 45s                 # exit 1 — staling either mark is enough
```

Both marks are required, not just the first.

One trap while checking this by hand: `kubectl exec deploy/worker` picks any pod
matching the deployment, and during a rollout that can still be the old one.
Read the marks on a pod named explicitly.

### 9. A rolling deploy keeps the queue covered

Scenario 6 kills a pod outright. A deploy is the more interesting case,
because KUBERNETES.md claims the startup probe *incidentally fixes rollouts
where the old pod was removed before the new one had subscribed* — and that
claim is about ordering, which needs two pods to be watched at once.

`kubectl rollout restart deploy/worker`, with `WORKER_COUNT=2`, so a fully
subscribed pod is worth two consumers per queue. Counting consumers on the
broker is what makes the ordering visible:

| after | consumers on the queue | pods |
|---|---|---|
| 1 s | 2 | old Ready, new Pending |
| 10 s | **4** | old Ready, new Running but **not** Ready |
| 16 s | — | the old pod cancels its consumers |
| 18 s | 2 | new pod only, Ready |

Coverage went 2 → 4 → 2 and never dipped. The new pod had subscribed before
the old one was asked to stop, and the old one logged no ERROR on its way out.

The mechanism is worth being explicit about, because it is the probe doing it:
a container running its startup probe is not Ready, and with one replica
`maxUnavailable: 25%` rounds down to zero, so Kubernetes may not remove the
old pod until the new one is Ready. Readiness here means *the mark is on
tmpfs*, which means the consumers are subscribed. A probe that answered on
process liveness instead would have released the old pod while the new one was
still booting.

### 10. The alert's metric is the one the docs name

The [consumer alert](KUBERNETES.md#required-companion-an-alert-on-consumers) is
part of the design, not a suggestion — so its expression deserves the same
treatment as everything else here. The broker in this fixture is enough to check
it; the plugin is not on by default:

```bash
kubectl exec deploy/rabbitmq -- rabbitmq-plugins enable rabbitmq_prometheus
```

Then read all three endpoints from the worker pod, which has a Ruby but no
`curl`:

```bash
kubectl exec deploy/worker -- ruby -rnet/http -e \
  'puts Net::HTTP.get(URI("http://rabbitmq:15692/metrics/detailed?family=queue_consumer_count"))'
```

Recorded on RabbitMQ 3.13.7:

| endpoint | what comes back |
|---|---|
| `/metrics` | `rabbitmq_queue_consumers 4` — one label-less cluster total |
| `/metrics/detailed` | telemetry and build info only, no queue metrics |
| `/metrics/detailed?family=queue_consumer_count` | `rabbitmq_detailed_queue_consumers{vhost="/",queue="kicks_liveness.alpha"} 2` |

Three things follow, and all three are now in the manifest documentation: the
metric is a *different* name from the aggregate, the detailed endpoint needs the
`family` parameter, and the series carries a `vhost` label.

Then check the two halves of the alert against a throwaway queue — declare one
with no consumers, scrape, delete it, scrape again:

```
-- queue exists, zero consumers
   rabbitmq_detailed_queue_consumers{vhost="/",queue="kicks_liveness.tmpcheck"} 0
-- queue deleted
   (no such series)
```

Both halves matter and they are different failures. An **idle** queue reports
`0`, which is what `== 0` is for. A **deleted** queue reports nothing at all,
and neither does a stopped broker or a stopped exporter — so `== 0` cannot fire
on the very failure scenario 3 demonstrates, where the queue goes away and the
pod is restarted. That is why the documented rule set pairs it with
`absent_over_time`, and why an `up == 0` on the scrape job is worth having
beside both.

### 11. A private-PID container restart cannot inherit a healthy mark

This scenario needs the fixture image but not Kubernetes or RabbitMQ. It starts
a container that publishes a healthy mark into a named volume, restarts that
same container, and delays the new writer for 15 seconds:

```bash
spec/integration/verify.sh build
spec/integration/verify.sh generation-restart
```

During the delay the inherited mark is still fresh, but the probe must reject
its old generation. Once the replacement writer publishes its own mark, the
same probe must become healthy again. The command checks both transitions and
prints output in this form:

```
before=mnt:[4026532686]:123456
after=mnt:[4026532686]:123789
inherited=heartbeat belongs to a previous container: worker has not started yet
recovered=1 process(es) healthy
```

The namespace inode is allowed to be reused, as in the example above; the PID 1
start time still distinguishes the two incarnations. The test removes its
container and named volume on exit.

This scenario covers the default container-private PID namespace. With
`shareProcessNamespace: true` or `hostPID: true`, PID 1 survives the worker
container restart and this guarantee does not hold; see
[LIMITATIONS.md](LIMITATIONS.md#container-generations-require-linux-procfs-and-container-owned-pid-1).

## What to do with a disagreement

Record it, then fix whichever is wrong — the code or the document. The numbers
above are a baseline: the arithmetic in KUBERNETES.md is meant to predict them,
and a scenario that lands far from its prediction means one of the two is out of
date.
