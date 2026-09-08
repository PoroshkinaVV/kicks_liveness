# Contributing

## Running the suite

```bash
bundle exec rake                      # rspec + rubocop
bundle exec yard stats --list-undoc   # documentation coverage
```

`rake` is the gate: it has to be green on **both** worker gems before anything
is merged.

## The two environment variables

This gem declares neither `kicks` nor `sneakers` as a dependency — at runtime it
needs only the `Sneakers` namespace, and both provide it. So the Gemfile has to
be told which one to resolve, and the suite has to pass against either.

| Variable | Value | What it is for |
|---|---|---|
| `AMQP_WORKER_GEM` | `kicks` (default) or `sneakers` | Picks the worker gem. The two also drag in different `bunny` majors, which is what makes this a real compatibility check rather than a formality |
| `AMQP_WORKER_GEM_VERSION` | an exact version, e.g. `3.0.0` | Pins that gem instead of resolving the newest the `~>` allows. This is what checks the **floor** the gemspec and the docs promise. An empty string counts as unset |

```bash
# the other line
AMQP_WORKER_GEM=sneakers bundle install && AMQP_WORKER_GEM=sneakers bundle exec rspec

# the oldest supported release of each
AMQP_WORKER_GEM=kicks    AMQP_WORKER_GEM_VERSION=3.0.0  bundle install && bundle exec rspec
AMQP_WORKER_GEM=sneakers AMQP_WORKER_GEM_VERSION=2.11.0 bundle install && bundle exec rspec

bundle install   # put the lock back on the default
```

`Gemfile.lock` is not committed, so switching between them costs nothing but a
resolve.

## How that maps onto CI

- The **`spec`** matrix crosses rubies 3.1 → 4.0 (plus `head`, allowed to fail)
  with both worker gems. Its Gemfile constraints are `~>`, so it always resolves
  the **newest** release of each.
- The **`floor`** job pins the exact oldest supported versions instead. It is a
  separate job on purpose: a GitHub Actions `include:` whose existing keys match
  a combination *extends that job* rather than adding one, so folding the floors
  into the matrix would have replaced the plain ruby 3.1 runs instead of joining
  them.

A `~>` matrix on its own proves the newest version works and says nothing about
the oldest. Both halves are needed to keep `>= 3.0` / `>= 2.11` honest.

## Integration scenarios

`rake` deliberately does not run them: nothing under `spec/integration/` is a
`_spec.rb`, so `rspec` never collects it. They need a local Kubernetes cluster
and a real broker, and they are documented as a runbook in
[docs/VERIFYING.md](docs/VERIFYING.md) — including what each scenario is meant to
prove and the values actually observed.

```bash
spec/integration/verify.sh build
spec/integration/verify.sh up
spec/integration/verify.sh down
```

## Documentation

`docs/` ships inside the gem (see `spec.files` in the gemspec), so a change
there is a change to the published artifact. Two habits that have already paid
off:

- **Measure rather than recall.** Numbers in the docs are observed values, and
  they say where they came from. If you cannot reproduce a number, say so
  instead of quoting it.
- **State the condition.** A claim that holds only under some configuration —
  a rollout guarantee that needs `maxUnavailable: 0`, a probe command that needs
  the gem in `GEM_HOME` — is worth less than nothing without the condition,
  because it reads as unconditional.
