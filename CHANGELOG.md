# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

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

[0.1.0]: https://github.com/PoroshkinaVV/kicks_liveness/releases/tag/v0.1.0
