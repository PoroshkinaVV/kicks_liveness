# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/PoroshkinaVV/kicks_liveness/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/PoroshkinaVV/kicks_liveness/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/PoroshkinaVV/kicks_liveness/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/PoroshkinaVV/kicks_liveness/releases/tag/v0.1.0
