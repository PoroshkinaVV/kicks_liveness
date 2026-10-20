# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- Bound the graceful-shutdown heartbeat exemption. The first stop notification
  starts a monotonic deadline; repeated callbacks cannot extend it. Once it
  expires, the monitor logs one ERROR and stops refreshing its slot mark while
  continuing to declare the expected fork count. A stuck drain can then fail
  the ordinary freshness check instead of remaining healthy indefinitely.
  The monitor does not terminate the process.

### Added

- Add `shutdown_grace` and `KICKS_LIVENESS_SHUTDOWN_GRACE`, defaulting to 60
  seconds. The initializer overrides the environment. Set it to at least your
  deployment's `terminationGracePeriodSeconds` to preserve the whole drain
  budget. Expiry stops writes; probe failure still waits for `max_age` and
  restart still depends on the kubelet's probe schedule and failure threshold.

## [0.1.3] - 2026-10-21

### Fixed

- Detect and reject PID topologies in which the container generation cannot
  identify an incarnation. `shareProcessNamespace: true` and `hostPID: true`
  leave PID 1 alive across a restart of the worker container, so the 0.1.2
  identifier can repeat and an inherited fresh heartbeat could satisfy
  `startupProbe`. Rejection is conditional on a readable `/proc/1/ns/mnt`.
  Where the comparison can be made, the worker publishes `<dir>/topology-unsafe`
  instead of a heartbeat and every probe exits 1 with
  `unsupported PID topology: pod must not set shareProcessNamespace or hostPID`,
  including one that cannot read the link itself; the state is terminal for the
  marks volume, and recovery is recreating the pod without those settings.
  Where it cannot, the previous behavior remains and the worker warns once. The
  measured outcomes are in `docs/LIMITATIONS.md`.
- Distinguish a valid zero in PID 1's stat start-time field from a stat line
  that cannot be parsed: the generation stays unavailable, and the warning
  names `hostPID` or a virtualized procfs instead of a false parse error.
- Scope the `attempt-<slot>` respawn counter to the container generation. A
  replacement container starts its own unhealthy run and cannot escalate over
  starts it did not take, while respawns within one generation go on sharing a
  count. Where no generation is available the counter keeps its previous
  volume-wide behavior.

### Added

- Report a degraded container generation once from the worker, at WARN — once
  per container incarnation where a generation exists, once per error state
  where it does not. Neither degraded state adds anything to the probe's
  output, and the intentional non-Linux fallback stays silent.
- The marks directory gains two files that appear only when something is
  wrong: `topology-unsafe`, the terminal fail-closed state, and
  `topology-report`, the worker's own flag for saying each thing once. Tooling
  that enumerates the directory should allow for both.
- Document the boundary of the graceful-shutdown exemption in
  `docs/LIMITATIONS.md`: a SIGTERM that does not come from a pod deletion can
  leave a pod Ready with no consumers. Existing behavior, newly documented.
- Add `spec/integration/verify.sh topology`, a Linux matrix covering a shared
  PID namespace, the host PID namespace, a verified private-PID container, and
  a private-PID container whose checker cannot read `/proc/1/ns/mnt`.

### Changed

- `Heartbeat#declare!` documents its actual `Integer` return value.
- Replace `Heartbeat.container_generation` with `Heartbeat.topology`, returning
  a structured result instead of a string or `nil`; replace the `Heartbeat.new`
  keyword `generation:` with `topology:`, accepting that result; and remove
  `KicksLiveness::GenerationGuard`. All are `@api private`, but callers need
  updating.

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
