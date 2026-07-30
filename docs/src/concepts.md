# Core concepts

## Promises settle once

A `PROMISE` starts `:PENDING` and moves to `:FULFILLED` (via `DELIVER`) or
`:FAILED` (via `DELIVER-ERROR`) exactly once. A second `DELIVER` or
`DELIVER-ERROR` signals `PROMISE-ALREADY-FULFILLED` rather than silently
overwriting the first result -- a promise delivered twice is almost always a
bug in the caller, not a legitimate update.

`AWAIT` blocks until the promise settles, then either returns the delivered
value or re-signals the delivered condition, preserving its type so
`HANDLER-CASE` on the awaiting side can still discriminate.

`FUTURE` is sugar for "make a promise, spawn a thread that settles it with
its body's outcome, return the promise immediately".

## Channels: buffered vs. unbuffered

`(MAKE-CHANNEL :BUFFER-SIZE 0)` (the default) is a true CSP rendezvous: `SEND`
does not return until a `RECV` has taken the value back out. This is a
stronger guarantee than "enqueued somewhere" -- it is a synchronization
point between the sending and receiving threads, exactly like Go's
unbuffered channel.

`(MAKE-CHANNEL :BUFFER-SIZE N)` for `N > 0` is a bounded queue: `SEND` only
blocks once `N` values are already waiting.

Closing a channel (`CLOSE-CHANNEL`) stops future `SEND`s (they signal
`CHANNEL-CLOSED`) but lets `RECV` keep draining whatever was already queued;
only once the channel is both closed and empty does `RECV` return `(VALUES
NIL NIL)`.

`TRY-SEND` and `TRY-RECV` never block. `TRY-SEND` on an unbuffered channel in
particular trades away the "a receiver actually took it" guarantee that
blocking `SEND` provides, in exchange for never waiting.

## Select doesn't poll

`SELECT` waits on several channel operations and runs whichever becomes
ready first. It is not a busy-poll loop: see [Architecture](architecture.md)
for how it sleeps between attempts.

Each `recv` channel form and each `send` channel/value form is evaluated
exactly once, in clause order, before `SELECT` probes for a ready operation.
This makes side-effecting setup expressions predictable even when a timeout
causes multiple readiness checks.

For static clauses, `SELECT` expands each `TRY-RECV` or `TRY-SEND` probe
directly. The ready path does not construct a runtime operation table or
dispatch through a selected index; the once-only bindings retain the same
evaluation and cleanup semantics.

`SELECT` gives clauses deterministic declaration-order priority when more
than one is ready. A receive from a closed and drained channel is ready too,
binding its value variable to `NIL`; a send to a closed channel signals
`CHANNEL-CLOSED` just as `SEND` does. `:DEFAULT` and `:TIMEOUT` are mutually
exclusive, and a form must contain at least one channel clause.

## Executors vs. futures

`FUTURE` spawns one thread per task. `MAKE-EXECUTOR` starts a fixed pool of
worker threads up front and `SUBMIT` hands them work through a shared queue,
returning a `PROMISE` just like `FUTURE` does. Reach for an executor when the
number of tasks is large or unbounded and one-thread-per-task would be
wasteful.

## Structured concurrency: scopes own their children

`WITH-TASK-SCOPE` establishes a scope; `SPAWN` starts a tracked child task on
a new thread and returns a `PROMISE` for it. The scope guarantees:

- **No child outlives the scope.** `WITH-TASK-SCOPE` does not return until
  every `SPAWN`ed thread has finished, whether it succeeded, failed, or is
  still running when the body itself throws.
- **A child's failure is never silently dropped.** If the body returns
  normally but one or more children failed, `WITH-TASK-SCOPE` signals
  `SCOPE-ERROR` with every failure's condition in `SCOPE-ERROR-CAUSES`.
- **Failure cancels siblings, cooperatively.** cl-concurrent-kit cannot
  forcibly interrupt a running SBCL thread, so a failing child trips a flag
  on the scope; other tasks must call `CHECK-CANCELLED` at a safe point to
  observe it and unwind via a signaled `TASK-CANCELLED`.
- **The body's own error wins.** If the body itself signals (rather than a
  `SPAWN`ed child), that condition propagates as-is after every child has
  been cancelled and awaited -- it is not wrapped in `SCOPE-ERROR`.
