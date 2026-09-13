# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.3] - 2026-10-21

### Fixed

- Detect and reject PID topologies in which the container generation cannot
  identify an incarnation. `shareProcessNamespace: true` and `hostPID: true`
  leave PID 1 alive across a restart of the worker container, and the mount
  namespace inode is normally handed straight back to the replacement, so the
  0.1.2 identifier repeats and an inherited fresh heartbeat could satisfy
  `startupProbe`. Where the namespace links can be read, both settings are now
  proven unsafe: the probe exits 1 with
  `unsupported PID topology: pod must not set shareProcessNamespace or hostPID`,
  and the worker publishes `<dir>/topology-unsafe` instead of a heartbeat, so a
  probe that cannot read PID 1's link fails too. The state is terminal for the
  marks volume; recovery is recreating the pod without those settings. Pods
  already using either setting will fail their probes after this upgrade
  instead of silently losing the guarantee.
- Scope the `attempt-<slot>` respawn counter to the container generation. A
  replacement container no longer inherits the previous container's unhealthy
  run: it logs its own `started:` line and cannot escalate over starts it did
  not take. Where no generation is available the counter keeps its previous
  volume-wide behavior.

### Added

- Report a degraded container generation once from the worker, at WARN. An
  unreadable `/proc/1/ns/mnt` is treated as an unverifiable topology rather
  than as proof of an unsafe one: the 0.1.2 generation check and the probe's
  own output are unchanged, and the warning is emitted once per container
  incarnation. A generation that cannot be derived at all on Linux retains the
  0.1.1 freshness-only fallback and warns once for as long as that state lasts.
  Neither state adds anything to the probe's stdout, and the intentional
  non-Linux fallback stays silent.
- The marks directory gains two files that appear only when something is
  wrong: `topology-unsafe`, the terminal fail-closed state, and
  `topology-report`, the worker's own flag for saying each thing once. Tooling
  that enumerates the directory should allow for both.
- Add `spec/integration/verify.sh topology`, a Linux matrix covering a shared
  PID namespace, the host PID namespace, a verified private-PID container, and
  a private-PID container whose checker cannot read `/proc/1/ns/mnt`.

### Changed

- `Heartbeat#declare!` documents its actual `Integer` return value.
- Replace `Heartbeat.container_generation` with `Heartbeat.topology`, which
  returns a structured result rather than a string or `nil`; rename the
  `Heartbeat.new` keyword `generation:` to `topology:`, which takes that result;
  and remove the `KicksLiveness::GenerationGuard` module, whose methods are now
  private to `Heartbeat`. All three are `@api private`, but a process that
  called them by name needs updating.

## [0.1.2] - 2026-09-11

### Fixed

- Reject heartbeat files inherited from a previous container incarnation. A
  Kubernetes `emptyDir` survives container restarts, so a fresh mark left by a
  formerly healthy worker could make the next container pass `startupProbe`
  before its consumers had subscribed. Cache files elsewhere in the same
  `emptyDir` remain untouched and available to warm the next application boot.
  This protection assumes the default container-private PID namespace; pods
  using `shareProcessNamespace` or `hostPID` retain the 0.1.1 freshness-only
  behavior (see `docs/LIMITATIONS.md`).
  The marks directory now contains `<dir>/generation`, and each
  `worker-<slot>` mark carries the same value; tooling that enumerates the
  directory should allow for this new metadata file.

## [0.1.1] - 2026-09-09

### Added

- Add a repository-hosted social-preview asset for the project documentation.

### Changed

- Rework the README into a shorter entry point while retaining the operational
  detail in the focused guides under `docs/`.
- Reject initializer values where `tick >= max_age`, and require
  `startup_grace_ticks` to be a positive integer. Initializers that previously
  supplied either invalid value now stop application boot with `ArgumentError`.
- Reject bundles that activate both `kicks` and `sneakers` with `LoadError`
  instead of letting their shared `lib/sneakers.rb` resolve silently by
  load-path order. Applications that still bundle both worker gems must remove
  one before upgrading.
- Replace the contributor-only `AMQP_WORKER_GEM` and
  `AMQP_WORKER_GEM_VERSION` test selection with Appraisal-generated dependency
  sets, including current and supported-floor targets for both worker gems.

### Fixed

- Recover environment values where `tick >= max_age` with a warning and a safe
  interval, preventing a healthy heartbeat from becoming stale between normal
  monitor ticks.
- Keep worker startup, heartbeat publication, and the monitor loop alive when a
  custom logger raises while handling an INFO or ERROR event.
- Correct the runtime-scaling documentation: live changes to `workers` are not
  supported in either direction. During scale-up, old and new forks otherwise
  race to publish different expected counts; during scale-down, retired slots
  remain expected.
- Strengthen the release gate with floor-version coverage, style checks, tag
  ancestry validation, and a packaged-executable smoke test.
- Include `.yardopts` in the gem so RubyDoc builds the intended README and
  public guide set from the packaged release.

## [0.1.0] - 2026-09-08

### Added

- First public release. A liveness probe for
  [Kicks](https://github.com/ruby-amqp/kicks) and
  [Sneakers](https://github.com/jondot/sneakers) workers: the worker publishes a
  liveness mark to tmpfs, checking its consumers against the Bunny objects in
  the process's memory, while the probe reads nothing but the mtime — no Rails
  and no call to the broker.

  What it does and why it is built this way is in
  [docs/](https://github.com/PoroshkinaVV/kicks_liveness/tree/main/docs); start
  with `SETUP.md`, and read `LIMITATIONS.md` before relying on it.

[Unreleased]: https://github.com/PoroshkinaVV/kicks_liveness/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/PoroshkinaVV/kicks_liveness/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/PoroshkinaVV/kicks_liveness/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/PoroshkinaVV/kicks_liveness/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/PoroshkinaVV/kicks_liveness/releases/tag/v0.1.0
