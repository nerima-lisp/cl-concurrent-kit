# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

### Changed

### Fixed

## [0.1.0] - 2026-07-30

### Added

- Initial release: thread/lock/condition-variable/semaphore primitives over
  `sb-thread`, plus a lock-free atomic counter.
- Promises/futures, including `promise-all-settled` to await a group of
  promises and collect each one's outcome without failing early.
- CSP channels (`send`/`recv`/`try-send`/`try-recv`/`close-channel`) with a
  Go-style `select` that picks the first ready clause in source order.
- A fixed-size executor (`make-executor`/`submit`); `shutdown-executor`
  supports `:cancel-pending` to reject queued-but-not-started work instead of
  running it.
- Structured-concurrency scopes (`with-task-scope`/`spawn`/`check-cancelled`)
  with cooperative cancellation; `spawn` accepts `:executor` to run a child on
  an executor's worker pool instead of a dedicated thread.
- `nix run .#coverage` to generate HTML and LCOV coverage reports.
