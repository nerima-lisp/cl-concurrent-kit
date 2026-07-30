# cl-concurrent-kit

A dependency-free, SBCL-only concurrency toolkit.

Common Lisp has no standard concurrency library, and bordeaux-threads exists
to paper over the differences between implementations' native thread APIs.
This project takes the opposite bet, in line with [nerima-lisp's coding
standard](https://github.com/nerima-lisp/.github/blob/main/CODING_STANDARD.md):
target SBCL only, wrap `sb-thread` directly, and spend the effort that
portability would have cost on a richer set of concurrency shapes instead.

## Layers

cl-concurrent-kit is five layers, each built only on the ones below it:

1. **Primitives** (`src/primitives.lisp`) -- threads, locks, condition
   variables, semaphores, and atomic counters. The vocabulary a portability
   layer such as bordeaux-threads would offer, minus the portability.
2. **Promise / future** (`src/promise.lisp`) -- a write-once result cell
   (`PROMISE`), a JS/Rust-style `FUTURE` macro that spawns a thread to settle
   one, and `PROMISE-THEN` for composing promises by continuation-passing
   instead of by blocking.
3. **Channel** (`src/channel.lisp`, queued through `src/fifo.lisp`) -- a
   Go-style CSP channel, buffered or unbuffered (true rendezvous), plus
   `SELECT` (`src/select.lisp`) for waiting on several of them at once.
4. **Executor** (`src/executor.lisp`) -- a fixed-size worker pool, Java's
   `ExecutorService`, built on `PROMISE` for its results and `src/fifo.lisp`
   for its work queue.
5. **Structured concurrency** (`src/scope-state.lisp`, `src/scope.lisp`) --
   `WITH-TASK-SCOPE`, a Kotlin/Swift/Python-trio-style nursery that
   guarantees every task `SPAWN`ed inside it has finished (or an optional
   `:TIMEOUT` has elapsed) before the scope returns, and that a failed
   task's condition always resurfaces.

See [Core concepts](concepts.md) for how they fit together, [Recipes](recipes.md)
for worked examples, and [Architecture](architecture.md) for the
implementation decisions behind `SELECT` and the unbuffered channel
rendezvous.
