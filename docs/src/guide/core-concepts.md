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

`PROMISE-THEN` composes promises by continuation-passing rather than by
blocking: `(PROMISE-THEN PROMISE ON-FULFILLED ON-REJECTED)` registers both
callbacks and returns a new promise for whichever one runs, settled from
whatever thread settles `PROMISE` -- immediately, inline, if `PROMISE` is
already settled. Chaining several calls builds a pipeline no thread ever
blocks to construct; only the final `AWAIT` blocks, if anything does.

`PROMISE-CATCH` and `PROMISE-FINALLY` are `PROMISE-THEN` specialized to only
the rejection or only the settlement path. `PROMISE-ALL`, `PROMISE-ANY`, and
`PROMISE-RACE` combine several promises into one CPS-composed the same way:
none of them blocks the calling thread, and each is settled the moment its
own condition is met by whichever input promise's settling thread satisfies
it. `CANCEL-PROMISE` settles a still-`:PENDING` promise from the outside with
`PROMISE-CANCELLED`, racing ordinarily against whatever would otherwise
deliver it -- whichever settles first wins, and the loser's attempt signals
`PROMISE-ALREADY-FULFILLED`.

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
ready first. It is not a busy-poll loop: see [Architecture](../reference/architecture.md)
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

An executor's queue is unbounded by default; passing `MAKE-EXECUTOR`'s
`:QUEUE-CAPACITY` makes `SUBMIT` reject work past that bound (with
`EXECUTOR-QUEUE-FULL`) instead of letting the queue grow without limit --
backpressure for a producer that can outrun its workers. `EXECUTOR-QUEUE-DEPTH`
and `EXECUTOR-HIGH-WATER-MARK` expose that queue's live and peak size for
observability. `WITH-EXECUTOR` scopes an executor's lifetime the way
`WITH-OPEN-FILE` scopes a stream's: the pool is shut down and its already-queued
work runs to completion on every exit from the body, normal or not.

## Structured concurrency: scopes own their children

`WITH-TASK-SCOPE` establishes a scope; `SPAWN` starts a tracked child task on
a new thread and returns a `PROMISE` for it. The scope guarantees:

- **No child outlives the scope.** `WITH-TASK-SCOPE` does not return until
  every `SPAWN`ed thread has finished, whether it succeeded, failed, or is
  still running when the body itself throws -- or until an optional
  `:TIMEOUT` (a `cl-date-kit:duration`) elapses waiting for stragglers, at which point
  `OPERATION-TIMED-OUT` is signaled instead and every remaining child is
  cancelled the same cooperative way a sibling failure would cancel them.
- **A child's failure is never silently dropped.** If the body returns
  normally but one or more children failed, `WITH-TASK-SCOPE` signals
  `SCOPE-ERROR` with every failure's condition in `SCOPE-ERROR-CAUSES`.
- **Failure cancels siblings, cooperatively.** A failing child trips a flag
  on the scope; other tasks must call `CHECK-CANCELLED` at a safe point to
  observe it and unwind via a signaled `TASK-CANCELLED`. That is a choice,
  not a missing mechanism -- `WITH-TIMEOUT` does forcibly interrupt a running
  SBCL thread, through SBCL's timer and `SB-THREAD:INTERRUPT-THREAD`, so the
  capability exists and is deliberately not used here. An asynchronous
  interrupt lands between two arbitrary instructions, so it can unwind a task
  whose `UNWIND-PROTECT` has not yet recorded the resource its cleanup would
  release; a scope exists precisely to guarantee that every child it started
  has finished and been accounted for, and that guarantee is worth more than
  reclaiming a task a few moments sooner. Bound work that is safe to abandon
  at an arbitrary point with `WITH-TIMEOUT`; for work that owns a resource,
  use a scope and `CHECK-CANCELLED`. See
  [Architecture](../reference/architecture.md#preemptive-with-timeout-cooperative-scopes).
- **The body's own error wins.** If the body itself signals (rather than a
  `SPAWN`ed child), that condition propagates as-is after every child has
  been cancelled and awaited -- it is not wrapped in `SCOPE-ERROR`.

Every scope keeps a set of *wakers* -- callbacks registered by whatever is
currently blocked on behalf of one of its children (`AWAIT-LATCH`,
`AWAIT-BARRIER`, and the reactive stream stages below all register one).
Cancelling the scope fires every waker exactly once, the same way it fires
every child's cancel callback, so a blocked wait unblocks promptly on
cancellation rather than only noticing on its own next timeout.

## Countdown latches and barriers

A `COUNTDOWN-LATCH` is one-shot: `COUNT-DOWN` decrements it, and once it
reaches zero it stays open forever, releasing every `AWAIT-LATCH` (present
and future) immediately. It composes with `WITH-TASK-SCOPE` the same way
`AWAIT` does: pass the scope explicitly via `AWAIT-LATCH`'s `:SCOPE`, and a
cancelled scope unblocks the wait with `TASK-CANCELLED` instead of leaving it
hanging until its own `:TIMEOUT`.

A `BARRIER` is the cyclic sibling: `PARTIES` callers must all call
`AWAIT-BARRIER` before any of them proceeds, and once released, the barrier
resets itself for a fresh generation rather than staying open. Any single
generation can *break* instead of releasing -- on a timeout, a cancelled
`:SCOPE`, or an explicit `RESET-BARRIER` -- in which case every party still
waiting in that generation signals `BARRIER-BROKEN` rather than proceeding
with fewer parties than promised.

## Reactive streams: stages over channels

The `CHANNEL-*` stream operators (`CHANNEL-MAP`, `CHANNEL-FILTER`,
`CHANNEL-MERGE`, and the rest) are all built from the same small piece of
machinery: a *stage* is a task -- run via `SPAWN` on a `:SCOPE`, submitted to
an `:EXECUTOR`, or run on its own `FUTURE` thread if neither is given -- that
reads an input channel (or channels), does some work, and writes an output
channel it alone owns and closes. Every stage-producing function returns two
values: the output channel and a completion `PROMISE` for the stage's own
task, so a caller who cares whether the stage itself succeeded or failed
(as opposed to just reading values off the output) can `AWAIT` it.

Ownership is the load-bearing invariant: because exactly one task ever writes
to and closes a given output channel, a downstream consumer can always tell
"no more values" from "closed" without racing another writer, and cancelling
a stage's `:SCOPE` closes its output rather than leaving a reader blocked
forever -- the same generic waker mechanism `AWAIT-LATCH` and `AWAIT-BARRIER`
use, registered before the stage's task starts and fired if the scope is
already, or becomes, cancelled.

Stages that fan in from several channels at once (`CHANNEL-MERGE`,
`CHANNEL-ZIP`, `CHANNEL-SWITCH-MAP`, and similar) are built on a small
variable-arity sibling of `SELECT` internal to the stream layer, for the same
reason `SELECT` itself exists: waiting on N channels without busy-polling any
of them.
