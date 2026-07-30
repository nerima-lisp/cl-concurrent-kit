# Architecture

## Why SBCL only, wrapping sb-thread directly

[nerima-lisp's coding standard](https://github.com/nerima-lisp/.github/blob/main/CODING_STANDARD.md)
targets SBCL exclusively and treats `sb-thread` as the default choice over
adding bordeaux-threads as an external dependency: every other repository in
the org that needs threads already calls `sb-thread` directly. This project
follows that precedent instead of reintroducing the portability layer it
would otherwise have depended on -- see `src/primitives.lisp` for the thin
wrapper this produces.

## The CONDITION-WAIT timeout contract

`SB-THREAD:CONDITION-WAIT` has a sharp edge: if its `:TIMEOUT` elapses, it
returns `NIL` **without reacquiring the mutex**. Code that assumes the lock
is still held after a `NIL` return will corrupt shared state or double-release
a mutex. `src/primitives.lisp`'s `%WAIT-UNTIL` centralizes the correct
pattern once (confirmed empirically against SBCL 2.6.0): every timeout path
routes through an actual `CONDITION-WAIT` call, so "timed out" and "lock not
held" are always the same event, never split across two branches.

## The unbuffered channel is a real rendezvous, not buffer-size-1

A common shortcut when implementing "unbuffered" channels is to treat them as
a buffer of size 1: cheap to write, but it lets `SEND` return as soon as the
value is enqueued, before anyone has received it -- losing the
happens-after guarantee that makes Go's unbuffered channels useful as a
synchronization primitive, not just a queue.

`src/channel.lisp` instead models capacity as `(MAX 1 BUFFER-SIZE)` for the
*enqueue* step (so unbuffered and buffered channels share one code path for
`SEND`/`RECV`/`TRY-SEND`/`TRY-RECV`), and then, only when `BUFFER-SIZE` is
zero, makes `SEND` wait a second time for the count to drop back to zero --
i.e. for a `RECV` to have actually taken the value back out. `SEND`
returning is therefore a real synchronization point between the two threads.

## SELECT sleeps; it does not poll

Waiting on several heterogeneous channels at once is the classic hard part of
implementing `select`: each channel has its own lock and its own send/recv
condition variables, and there is no single condition variable to block on
across all of them.

`src/select.lisp` solves this without busy-waiting by registering a private
semaphore as a temporary waiter on every channel involved
(`%CHANNEL-ADD-WAITER`, `src/channel.lisp`). Every state change on a
channel -- a value sent, received, or the channel closed -- signals that
semaphore in addition to the channel's own condition variables
(`%CHANNEL-NOTIFY`/`%CHANNEL-BROADCAST`). `SELECT`'s loop tries every clause
non-blockingly (via `TRY-SEND`/`TRY-RECV`, in source order, so the first
clause written wins ties), and only sleeps on its semaphore -- with a
computed remaining timeout, if any -- when nothing was ready.
`UNWIND-PROTECT` guarantees the waiter is removed from every channel before
`SELECT` returns, however it returns.

## Structured concurrency: why the body's own error is never wrapped

`WITH-TASK-SCOPE` distinguishes two failure sources deliberately:

- If a **`SPAWN`ed child** fails, its condition is recorded, cancellation is
  tripped for its siblings, and -- once the scope's body has itself returned
  and every child has been awaited -- all recorded failures resurface
  together in one `SCOPE-ERROR`.
- If the **body itself** signals (not a child), that condition is what a
  caller almost always cares about diagnosing; wrapping it in `SCOPE-ERROR`
  alongside unrelated child failures would obscure the actual fault. It
  therefore propagates as-is, after cancellation and awaiting still run via
  `UNWIND-PROTECT`, so no child outlives the scope regardless of which way it
  exits.

Cancellation is cooperative rather than forced because cl-concurrent-kit has
no safe way to interrupt an arbitrary running SBCL thread; `CHECK-CANCELLED`
is the hook a long-running task calls at a point where stopping is safe.
`WITH-TASK-SCOPE` accepts an optional `:TIMEOUT` (seconds) bounding only the
wait for already-running children once the body itself has finished; on
expiry every remaining child is cancelled the same cooperative way and
`OPERATION-TIMED-OUT` is signaled. `TASK-SCOPE`'s own bookkeeping (the
struct, child registration, cancellation) lives in `src/scope-state.lisp`;
`src/scope.lisp` is `SPAWN`'s dispatch and the `WITH-TASK-SCOPE` macro itself,
which runs its body inline via `LOCALLY` rather than through an intervening
closure -- one fewer indirection between a `CHECK-CANCELLED` or `SPAWN` call
in the body and the call itself.

## One deadline-wait shape, one macro

`AWAIT`, `SEND`, `RECV`, and `WITH-TASK-SCOPE`'s child wait all follow the
same shape: compute a deadline once from a `:TIMEOUT` in seconds, block on
`%WAIT-UNTIL` until a predicate is satisfied or the deadline passes, and
signal `OPERATION-TIMED-OUT` on the latter. `src/primitives.lisp`'s
`%WITH-DEADLINE-WAIT` macro is that shape written once; every caller supplies
only what actually varies -- the condition variable, the lock, the predicate,
and the operation keyword the resulting condition names. `src/channel.lisp`'s
unbuffered `SEND` calls it twice against one shared deadline (see its own
comment for why the deadline, not the timeout, is what must not be
recomputed between the two waits).

## PROMISE-THEN: continuation-passing composition without blocking

`PROMISE-THEN` (`src/promise.lisp`) is built directly on the same
continuation-registration primitive `PROMISE-ALL-SETTLED` already used
internally (`%OBSERVE-PROMISE`): register a callback to run once a promise
settles, called synchronously by whichever thread does the settling -- or
immediately, inline, if the promise is already settled. `PROMISE-THEN` wraps
that in the familiar `.then()` shape (fulfilled/rejected continuations,
returning a new promise for whichever one ran) without introducing a thread,
a queue, or any blocking wait: the composition is the continuation passing
itself.

## Why SRC/PACKAGE.LISP declaims SPEED 0

`src/package.lisp` proclaims `(optimize (speed 0) ...)` globally, and that
declaim carries a load-bearing comment explaining why: at SBCL 2.6.0's
default `SPEED 1`, compiling this system in one image -- specifically
`SPAWN-CHILD` in `src/scope.lisp`, once `src/select.lisp`,
`src/executor.lisp`, and `src/scope-state.lisp` have all already
contributed type information to the same compilation -- triggers a
constraint-propagation pathology in SBCL's compiler that does not return in
any practical time. Every operation in this library is dominated by a mutex
acquisition or an OS-level wait, so `SPEED` was never the bottleneck a caller
could measure; trading it for a compiler that terminates costs nothing real.
See the declaim's own comment for the bisection that isolated it.
