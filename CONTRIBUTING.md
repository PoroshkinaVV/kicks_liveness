# Contributing

Bug reports are welcome in
[GitHub Issues](https://github.com/PoroshkinaVV/kicks_liveness/issues), and code
changes in [pull requests](https://github.com/PoroshkinaVV/kicks_liveness/pulls).

For worker or liveness bugs, please include:

- Which worker gem and which version — for example, `kicks 3.4.0` or
  `sneakers 2.11.0`.
- The `kicks_liveness` and Ruby versions.
- `KICKS_LIVENESS_DIR`, `KICKS_LIVENESS_TICK` and `KICKS_LIVENESS_MAX_AGE` as
  they are actually set in the pod.
- Anything passed to `KicksLiveness.configure`.
- What the probe printed and its exit status:
  `bundle exec kicks-liveness; echo "exit=$?"`.
- The worker's `[liveness]` log lines from around the failure.

## Getting set up

Ruby **3.1** or newer, matching `required_ruby_version` in the gemspec.

```bash
bundle install          # required first: the Gemfile has to resolve a worker gem
bundle exec rake        # fast loop: rspec + rubocop for the current worker gem
bundle exec rake ci     # complete non-integration CI gate; run before a pull request
```

`rake ci` installs and tests every dependency set in `Appraisals`. It does not
modify the ignored root `Gemfile.lock`: each appraisal has its own ignored
lockfile. The task also runs RuboCop, the YARD build that rubydoc.info will
publish, and a check that the committed `gemfiles/` match `Appraisals`.
Everything has to be green before a change is merged.

## Dependency matrix

This gem declares neither `kicks` nor `sneakers` as a dependency — at runtime it
needs only the `Sneakers` namespace, and both provide it (the reasoning is in
[docs/LIMITATIONS.md](docs/LIMITATIONS.md)). The root Gemfile uses Kicks for the
fast development loop; `Appraisals` is the single source of truth for the full
compatibility matrix.

| Appraisal | Worker requirement |
|---|---|
| `kicks-current` | `kicks ~> 3.0` |
| `kicks-3-0` | `kicks 3.0.0`, the supported floor |
| `sneakers-current` | `sneakers ~> 2.11` |
| `sneakers-2-11` | `sneakers 2.11.0`, the supported floor |

```bash
bundle exec appraisal list
bundle exec appraisal sneakers-current bundle install
bundle exec appraisal sneakers-current rspec
```

After changing `Appraisals`, run `bundle exec appraisal generate` and commit the
generated `gemfiles/*.gemfile`; their lockfiles stay ignored. Your pull request
runs the current Kicks and Sneakers appraisals on Ruby 3.1 through 4.0, both
oldest supported versions on Ruby 3.1, and RuboCop and YARD once apiece.

## Integration scenarios

`rake` deliberately does not run them: nothing under `spec/integration/` is a
`_spec.rb`, so `rspec` never collects it. They need a local Kubernetes cluster
and a real broker, and they are documented as a runbook in
[docs/VERIFYING.md](docs/VERIFYING.md) — including the prerequisites, what each
scenario is meant to prove, and the values actually observed.

```bash
spec/integration/verify.sh build     # image, into the engine the cluster uses
spec/integration/verify.sh status    # print and verify the exact target
spec/integration/verify.sh up        # namespace, broker, worker
spec/integration/verify.sh probe     # runs the probe both ways, prints exit codes
spec/integration/verify.sh marks     # lists the heartbeat files
spec/integration/verify.sh logs [n]  # worker logs
spec/integration/verify.sh ui        # port-forwards the RabbitMQ management UI
spec/integration/verify.sh down      # deletes the namespace
```

To build the fixture with the other worker implementation:

```bash
AMQP_WORKER_GEM=sneakers spec/integration/verify.sh build
```

The script never uses Kubernetes' `current-context`, but it operates on the
explicitly configured context and namespace. Run `status` and verify both before
`up` or `down`. A namespace created by `up` is labelled as owned by the fixture;
`up` and `down` refuse to touch an existing namespace without that label.

| Variable | Value | What it is for |
|---|---|---|
| `KICKS_LIVENESS_K8S_CONTEXT` | `docker-desktop` (default), or any kube context | The context every call names. The script exits if it does not exist rather than falling back to whatever `current-context` points at. |
| `KICKS_LIVENESS_K8S_NAMESPACE` | `kicks-liveness` (default), or any namespace | The fixture-owned namespace `up` creates and `down` deletes whole. Do not point this at one you need. |
| `KICKS_LIVENESS_DOCKER_CONTEXT` | `desktop-linux` (default), or any docker context | The context `build` builds the image into. It has to be the engine backing the cluster: on a machine that also runs OrbStack or Colima the default is not Docker Desktop's, and the pod then fails with `ErrImageNeverPull`. |

## Documentation

`docs/` ships inside the gem (see `spec.files` in the gemspec), so a change
there is a change to the published artifact. Two rules for it:

- **Measure, do not recall.** A number in the docs is an observed value and says
  where it came from. If you cannot reproduce one, drop it rather than quote it.
- **State the condition.** A claim that holds only under some configuration — a
  rollout guarantee that needs `maxUnavailable: 0`, a probe command that needs
  the gem in `GEM_HOME` — has to carry that condition, or it reads as
  unconditional.

Each rationale has one home; elsewhere, link to it.

## Sending a pull request

- Keep one topic per pull request. Behaviour changes need tests; bug fixes
  should include a regression spec that fails before the fix. Documentation-only
  and maintenance changes do not require a spec.
- For a user-visible change, add a `CHANGELOG.md` entry under the
  `## [Unreleased]` heading, in the
  [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) category the file
  already uses. Tests, refactors, CI maintenance, and typo-only documentation
  changes do not need an entry.
- Run `bundle exec rake ci`, and re-read anything in `docs/` or `README.md` that
  your change makes untrue.
- Document new public API with YARD: `@param`, `@return`, and `@raise` where it
  raises. Mark internals `@api private`, as the existing ones are.
  `bundle exec yard stats --list-undoc` names what you missed.
- If the change touches the probe's behaviour in the cluster, say which
  `docs/VERIFYING.md` scenario you re-ran and what you saw.
