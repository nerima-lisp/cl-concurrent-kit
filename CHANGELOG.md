# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `promise-then`: continuation-passing composition for promises. Registers
  fulfilled/rejected continuations and returns a new promise for whichever
  one runs, without blocking or spawning a thread.
- `with-task-scope` accepts `:timeout` (seconds), bounding the wait for
  already-running children once the body itself has finished; on expiry
  every remaining child is cancelled cooperatively and
  `operation-timed-out` is signaled.
- Property-based coverage for buffered-channel FIFO ordering
  (`it-property`/`gen-list`) and continuation-passing-style coverage for
  `promise-then` (`with-continuation-result`), both via cl-weave.
- `nix build .#coverage`, replacing the hand-rolled coverage app with
  cl-nix-forge's `mkCoverageReport`.

### Changed

- `src/channel.lisp`'s private FIFO queue moved to its own file,
  `src/fifo.lisp`, shared with `src/executor.lisp`'s work queue as before.
- `src/scope.lisp` split into `src/scope-state.lisp` (the `task-scope`
  struct and child bookkeeping) and `src/scope.lisp` (`spawn`'s dispatch and
  the `with-task-scope` macro itself). `with-task-scope` now runs its body
  inline via `locally` rather than through an intervening closure.
- Every condition in `src/conditions.lisp` is now generated through a
  `define-kit-condition` macro instead of five hand-written
  `define-condition` forms, so a slot's reader name and a `:report`
  method's boilerplate are written once.
- The repeated "compute a deadline, wait, signal `operation-timed-out` on
  timeout" shape in `await`, `send`, `recv`, and the new scope timeout is
  now one macro, `%with-deadline-wait` (`src/primitives.lisp`).
- `flake.nix` rewritten around cl-nix-forge's `mkPackageFlake`, replacing
  the hand-rolled `buildASDFSystem`/source-registry/checks wiring with the
  org-standard one-call preset. `cl-weave` bumped to v1.1.0.
- `src/package.lisp` now declaims `(optimize (speed 0) ...)` globally --
  see its own comment and [Architecture](architecture.md) for the SBCL
  compile-time pathology this avoids.

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
