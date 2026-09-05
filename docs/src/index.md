# cl-concurrent-kit

An SBCL-only concurrency toolkit, built directly on `sb-thread`.

Common Lisp has no standard concurrency library, and bordeaux-threads provides
a portability layer over implementation-specific thread APIs. This project
targets SBCL and wraps `sb-thread` directly, providing promises, channels,
executors, scopes, and streams in one library.
Every `:TIMEOUT` argument across that surface accepts a
[`cl-date-kit:duration`](https://github.com/nerima-lisp/cl-date-kit), with
  [`cl-boundary-kit`](https://github.com/nerima-lisp/cl-boundary-kit) supplying
  the injectable clock used for deadline arithmetic. See
  [Architecture](reference/architecture.md) for the integration details.

## Layers

cl-concurrent-kit is five layers, each built only on the ones below it:

1. **Primitives** (`src/primitives.lisp`) -- threads, locks, condition
   variables, semaphores, and atomic counters. The vocabulary a portability
   layer such as bordeaux-threads would offer, minus the portability.
2. **Promise / future** (`src/promise.lisp`) -- a write-once result cell
   (`PROMISE`), a JS/Rust-style `FUTURE` macro that spawns a thread to settle
   one, and `PROMISE-THEN` for composing promises by continuation-passing
   instead of by blocking.
3. **Channel** (`src/channel.lisp`, a preallocated ring buffer) -- a Go-style
   CSP channel, buffered or unbuffered (true rendezvous), plus `SELECT`
   (`src/select.lisp`) for waiting on several of them at once.
4. **Executor** (`src/executor.lisp`) -- a fixed-size worker pool, Java's
   `ExecutorService`, built on `PROMISE` for its results and its own
   preallocated ring buffer for its work queue.
5. **Structured concurrency** (`src/scope-state.lisp`, `src/scope.lisp`) --
   `WITH-TASK-SCOPE`, a Kotlin/Swift/Python-trio-style nursery that
   guarantees every task `SPAWN`ed inside it has finished (or an optional
   `:TIMEOUT` has elapsed) before the scope returns, and that a failed
   task's condition always resurfaces.

Three further pieces build on those five:

- **Preemptive timeouts** (`src/timeout.lisp`) -- `WITH-TIMEOUT`, the one
  deadline here that bounds an *arbitrary* body rather than a wait that this
  library implements itself, by interrupting the running thread. The
  counterpart to structured concurrency's cooperative
  cancellation, not a replacement for it.
- **Countdown latches and barriers** (`src/latch.lisp`) -- `COUNTDOWN-LATCH`
  and `BARRIER`, both able to take an optional `WITH-TASK-SCOPE` `:SCOPE` so
  a blocked wait unblocks on cancellation the same way `AWAIT` does.
- **Reactive streams** (`src/stream.lisp` and friends) -- `CHANNEL-*`
  operators (`CHANNEL-MAP`, `CHANNEL-MERGE`, `CHANNEL-DEBOUNCE`, and others)
  that compose channels into pipelines, each stage run via
  `SPAWN` or an executor rather than a hand-written read/transform/write
  loop.

See [Core concepts](guide/core-concepts.md) for how they fit together, [Recipes](guide/recipes.md)
for worked examples, and [Architecture](reference/architecture.md) for the
implementation decisions behind `SELECT` and the unbuffered channel
rendezvous.
