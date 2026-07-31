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
- Seven tests closing every remaining runtime-reachable branch gap
  `sb-cover` reported: `%scope-add-child`/`%scope-remove-child`/
  `%scope-set-child-cancel` racing with cancellation (`scope-state.lisp`),
  an executor-queued scope child cancelled by its own scope rather than by
  executor shutdown (`scope.lisp`), a buffered channel's `send` actually
  blocking and waking (`channel.lisp`), and `select` falling through an
  unready `send` clause to `:default` (`select.lisp`). Every `src/` file now
  reads 100% branch coverage except the type-check instrumentation noted in
  [README.md](README.md#development).
- A property-based test for `promise-all-settled`: for any generated mix of
  fulfilled and failed input promises, settlement order and classification
  are preserved (`it-property`/`gen-list`/`gen-boolean`).
- Two tests closing `scope.lisp`'s last runtime-reachable expression-coverage
  gaps (91.0% to 99.2%): an executor-backed `spawn` actually running its
  child to completion, and `%spawn-executor-child` removing the child
  registration and re-signaling when submitting to `executor` itself fails
  -- previously untested cleanup that, left unverified, could have silently
  regressed into a scope that hangs forever awaiting a child that was never
  really queued.
- [Stability](docs/src/compatibility.md#stability) section documenting the
  public API surface, the CI gate every change goes through, and how
  `flake.lock` is kept current.
- `promise-race`: a `PROMISE` that settles the same way as whichever input
  settles first, built as pure continuation-passing composition on
  `%observe-promise` -- no thread, no queue, no polling -- alongside
  `promise-then` and `promise-all-settled`.
- `benchmarks/run-benchmarks.lisp`: round-trip overhead for each primitive
  (channel send/recv, promise deliver/await, promise-then, executor
  submit/await, scope spawn/await) reported via cl-weave's `benchmark`.
- [Production readiness](docs/src/compatibility.md#production-readiness)
  section: error-handling philosophy, thread-safety and resource-cleanup
  contracts, cooperative-cancellation's known limitation, and this
  library's single-image scope.
- `with-soft-assertions` (cl-weave) around the multi-`expect` checks in
  `promise-all-settled` and closed-channel `recv`'s tests, so a failure in
  one no longer hides whether the others also failed.
- `src/fifo.lisp`'s FIFO is now an intrusive doubly-linked list (`fifo-cell`
  tracking its own `previous`/`next`/`linked-p`) instead of a plain cons-cell
  queue: `fifo-remove` deletes a specific cell in O(1) -- used by an
  unbuffered `send`'s timeout to retract the value it queued before any
  `recv` took it, so a timed-out send no longer leaves a phantom value for a
  future `recv` to hand out -- and `fifo-detach` empties the whole queue in
  O(1), used by `shutdown-executor :cancel-pending t` to reject every
  pending task without popping them one at a time.
- `channel`'s waiters moved from a list to a hash table keyed by an interest
  bitmask (`+channel-notify-send+`/`-recv+`/`-rendezvous+`/`-close+`) over
  separate send/recv/rendezvous condition variables, so a state transition
  wakes only the `select` calls actually registered for it instead of every
  waiter on the channel.
- `promise`'s observers append in O(1) via a tracked `observer-tail` instead
  of `push`ing and `nreverse`-ing the list in `%settle`; an observer
  callback that signals is now caught and its condition re-signaled only
  after every other observer has still been notified, instead of aborting
  notification of the rest.
- `executor`'s per-task state (`:pending`/`:running`/`:cancelled`) now
  transitions via `sb-ext:compare-and-swap` instead of a dedicated per-task
  lock, and a task's outcome -- run to completion or cancelled before a
  worker claimed it -- reaches its `on-settle` callback uniformly through
  one path (`%executor-task-settle`) rather than two.
- `src/scope-state.lisp` split further into `src/scope-state.lisp` (the
  `task-scope` struct and its low-level state transitions) and
  `src/scope-execution.lisp` (`spawn`'s dispatch to a dedicated thread or an
  executor), leaving `src/scope.lisp` with only `check-cancelled`,
  `%scope-signal-failures`, and the `with-task-scope` macro itself.
  `task-scope` gained a `closing-p` flag, set before `with-task-scope`
  starts awaiting its children, so a child racing to `spawn` itself in that
  window is rejected immediately instead of possibly slipping in after
  `%scope-await-children` has already taken its "no children left" snapshot.
- `benchmarks/run-benchmarks.lisp` gained a `select-ready-recv` benchmark
  alongside its existing coverage.
- `nix flake check` gained a `coverage-lcov` check and `nix run .#benchmark`
  an app, both driven by this project's own `run-coverage.lisp` and
  `scripts/verify-lcov.pl`, layered on top of (not instead of)
  cl-nix-forge's generic `mkCoverageReport`.
- `src/latch.lisp`: `countdown-latch` (Java's `CountDownLatch`) and `barrier`
  (Java's `CyclicBarrier`), both accepting an optional `:scope` -- passed
  explicitly exactly as `spawn`'s own `scope` argument is -- so a blocked
  `await-latch`/`await-barrier` also unblocks with `task-cancelled` (or, for
  a barrier, `barrier-broken`) when that scope is cancelled.
- `task-scope` gained a generic waker mechanism (`%scope-add-waker`/
  `%scope-remove-waker`, `src/scope-state.lisp`): an arbitrary zero-argument
  callback registered by whatever is currently blocked on the scope's
  behalf, invoked once, outside the scope's own lock, the same pass that
  invokes every child's cancel callback. `await-latch`, `await-barrier`, and
  every reactive stream stage below register one.
- `cancel-promise`, `promise-catch`, `promise-finally`, `promise-all`,
  `promise-any`, and `promise-timeout` (`src/promise-combinators.lisp`):
  further continuation-passing promise combinators built the same way as
  `promise-then`/`promise-race`/`promise-all-settled` -- no thread, no
  queue, no blocking wait, settled by whichever input's own settling thread
  satisfies the combinator first.
- Executor observability and backpressure (`src/executor.lisp`):
  `make-executor` accepts `:queue-capacity` to bound its work queue, after
  which `submit` rejects further work with `executor-queue-full` instead of
  growing without limit; `try-submit` reports acceptance without needing an
  `await`; `await-executor-termination` and `executor-shutdown-p`/
  `executor-terminated-p` expose lifecycle state directly; `executor-queue-depth`/
  `executor-queue-capacity`/`executor-high-water-mark` expose the queue's
  live and peak size; `with-executor` scopes an executor's lifetime the way
  `with-open-file` scopes a stream's; `executor-map` applies a function
  across a sequence with bounded concurrency and ordered results.
- A reactive stream layer of around thirty `channel-*` operators built on
  channels (`src/stream.lisp`, `src/stream-fan-out.lisp`,
  `src/stream-fan-in.lisp`, `src/stream-partition.lisp`): `channel-producer`,
  `channel-from-sequence`, `channel-map`, `channel-keep`, `channel-filter`,
  `channel-distinct-until-changed`, `channel-debounce`, `channel-throttle`,
  `channel-flat-map`, `channel-scan`, `channel-reduce`, `channel-collect`,
  `channel-each`, `channel-some`, `channel-every`, `channel-find`,
  `channel-broadcast`, `channel-take`, `channel-drop`, `channel-take-while`,
  `channel-batch`, `channel-partition-by`, `channel-map-concurrent`,
  `channel-map-unordered`, `channel-merge`, `channel-zip`, `channel-concat`,
  `channel-concat-map`, `channel-merge-map`, and `channel-switch-map`. Every
  stage owns and closes its output channel and returns a completion promise
  alongside it; fan-in stages (`channel-merge`, `channel-zip`,
  `channel-switch-map`, and similar) are built on a small variable-arity
  sibling of `select` internal to the stream layer, for the same reason
  `select` itself exists.

### Changed

- `src/promise.lisp` split into `src/promise.lisp` (the core write-once cell:
  `make-promise`/`deliver`/`deliver-error`/`await`, plus the thread-spawning
  `future`) and `src/promise-combinators.lisp` (`promise-all-settled`,
  `promise-race`, `promise-then` -- everything that derives a new promise
  from existing ones), matching the `scope.lisp`/`scope-state.lisp` and
  `channel.lisp`/`fifo.lisp` split already in this codebase.
- `%with-channel-lock`, `%with-work-queue-lock`, and `%with-scope-lock`
  replace eighteen hand-written `(with-lock-held ((X-lock obj)) ...)` call
  sites across `src/channel.lisp`, `src/executor.lisp`, and
  `src/scope-state.lisp`/`src/scope.lisp` with one named macro per struct's
  lock.
- `src/promise.lisp`'s `%deliver-on-thread` factors out the
  run-a-thunk-on-a-thread-and-settle-a-promise shape `future` and
  `src/scope.lisp`'s `%spawn-thread-child` had each written out separately.
- `src/channel.lisp`'s `%channel-signal-waiters` factors out the identical
  wake-every-registered-select-waiter `maphash` `%channel-notify` and
  `%channel-broadcast` had each written out separately.

- `t/package.lisp`'s `wait-or-fail` replaces twelve hand-duplicated `(unless
  (wait-on-semaphore sem :timeout 1) (error "..."))` guards across
  `t/executor-test.lisp` and `t/scope-test.lisp` with one named
  synchronization-checkpoint idiom.
- `src/scope.lisp`'s `spawn-child` split into `%spawn-executor-child` and
  `%spawn-thread-child`, one per dispatch strategy, so `spawn-child` itself
  reads as the two-way dispatch it is instead of both strategies' bodies
  inlined into one `if`.
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
