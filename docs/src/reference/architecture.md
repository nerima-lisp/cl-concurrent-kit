# Architecture

## Platform and dependencies

The library targets SBCL and wraps `sb-thread` through the small interface in
`src/primitives.lisp`. It depends on CL-DATE-KIT for duration values. Public
timeout arguments use `CL-DATE-KIT:DURATION`; callers can construct one with
`CL-DATE-KIT:DURATION-OF-SECONDS`, `-MILLIS`, `-MICROS`, or `-NANOS`.

Since v0.7.0, the special variable `*CLOCK*` is a zero-argument function that
returns internal-time units. Its default is `GET-INTERNAL-REAL-TIME`. Its
monotonicity depends on the SBCL build: when `:OS-PROVIDES-CLOCK-GETTIME` is
present in `SB-IMPL:+INTERNAL-FEATURES+`, SBCL uses `CLOCK_MONOTONIC` on macOS
and `CLOCK_MONOTONIC_COARSE` on Linux. Tests can bind a closure and advance its
returned value to exercise deadline arithmetic.

## Threading primitives

`src/primitives.lisp` defines the package's low-level protocol: threads,
mutexes, condition variables, semaphores, and atomic counters. Higher-level
code uses these wrappers instead of depending on implementation-specific
objects throughout the rest of the system.

`WITH-INTERRUPTIBLE-SCOPE` gives one invocation on the calling thread its own
interruption target. A request queues a transfer directly to that scope's
boundary. The transfer unwinds user cleanup without signaling a condition
inside the body. Only the boundary signals `OPERATION-INTERRUPTED`, so body
condition handlers cannot suppress the exit.

Completion and delivery can race. Their observable outcomes are:

| Ordering | Outcome |
|---|---|
| Delivery reaches the active body first | Unwind the body, run cleanup, then signal at the boundary. |
| The body returns before queued delivery | Preserve its return values and deactivate the scope so its queued callback cannot leave the boundary. |
| A request arrives during scope teardown or after exit | Ignore the request. It cannot affect a later invocation on the same thread. |
| Several requests reach one active scope | Accept the first reason and ignore later requests. |
| A signal handler on the target thread requests interruption | Queue delivery until after the handler returns. |
| An outer scope is interrupted while an inner scope runs | Unwind the inner scope and its cleanup before reaching the outer boundary. |

Teardown drains pending scope callbacks before returning when the caller
permits interrupts. If the caller
encloses the entire scope in `WITHOUT-INTERRUPTS`, callbacks can remain pending
until that enclosing prohibition ends. They then see an inactive scope and
do nothing, even though the boundary has already exited.

SBCL can also delay delivery during garbage collection. Callers must protect
resource acquisition and the state needed for cleanup against arbitrary
asynchronous exits.

`WITH-TIMEOUT` uses this same boundary with a timer requesting interruption.
It reports `OPERATION-TIMED-OUT` after unwinding. The readers
`OPERATION-TIMED-OUT-OPERATION` and `OPERATION-TIMED-OUT-TIMEOUT` report the
operation and timeout in seconds. A timer expiring during scope teardown
cannot replace a completed result. Other blocking operations enforce their deadline by
returning from their wait and signaling the package's timeout condition.

## Promises and executors

`PROMISE` is a single-assignment result cell. A promise has one terminal state:
fulfilled with values or failed with a condition. Observers are invoked once
when that state is reached; observer failures are isolated so later observers
still run.

The promise combinators are built from observation and do not poll.
`PROMISE-THEN`, `PROMISE-CATCH`, and `PROMISE-FINALLY` transform one result.
`PROMISE-ALL`, `PROMISE-ANY`, `PROMISE-RACE`, and `PROMISE-ALL-SETTLED`
combine several results. `PROMISE-TIMEOUT` adds a deadline to observation.

An executor owns worker threads and a bounded work queue. Submitting work
returns a promise. Shutdown prevents new work, lets accepted work drain, and
can wait for worker termination. Executor callbacks settle promises and keep
callback failures separate from worker failures.

## Channels and SELECT

`CHANNEL` is a rendezvous or buffered queue. `SEND` and `RECV` use the same
deadline model as other blocking operations and signal `CHANNEL-CLOSED` when a
closed channel has no remaining value. Closing a channel wakes both senders
and receivers.

`SELECT` is a macro because its clauses are registered together at
macroexpansion time. A clause can receive a value, send a value, or handle a
timeout/default case. The implementation registers waiters under the channel
lock, chooses one ready clause, removes the remaining waiters, and sleeps
between probes. This prevents a race from selecting a clause that is no longer
ready and avoids busy-waiting.

Stages that receive a runtime-sized channel set use the dynamic multiplexer
in `src/stream-fan-in.lisp`. It uses the same waiter protocol as `SELECT` but
can add and remove channels while it runs.

## Task scopes and cancellation

`WITH-TASK-SCOPE` tracks every task spawned in its dynamic extent and waits for
all children before returning. A task error is recorded and resurfaced by the
scope. Cancellation is cooperative: it marks the scope and wakes registered
waiters; task code observes the state with `CHECK-CANCELLED`.

Scope wakers connect cancellation to blocking primitives. A cancelled task
therefore leaves `RECV`, `SEND`, `SELECT`, latch, barrier, and executor waits
through their normal cancellation conditions. Cleanup unregisters each waker
and joins each child before the scope exits.

## Latches and barriers

`LATCH` is a one-shot notification. `COUNTDOWN-LATCH` reaches its terminal
state after the configured number of decrements. `BARRIER` releases a complete
generation of parties together and starts a new generation afterward. A
timed-out or cancelled wait breaks the current generation; `RESET-BARRIER`
creates a usable generation again.

## Stream stages

`src/stream.lisp` provides the common stage lifecycle. A stage owns an output
channel and a task scope, closes its output on normal completion, and closes it
through the scope waker on cancellation. Stage helpers cover mapping,
filtering, reduction, collection, rate limiting, batching, and windowed
operations.

Fan-in stages are split by channel topology:

- `stream-fan-in.lisp` handles merge, zip, concat, and dynamic inner channels.
- `stream-fan-out.lisp` handles broadcast and partitioning.
- `stream-transform.lisp` handles per-value transformations.
- `stream-window.lisp` handles throttle, debounce, take, drop, and batch.

Ordered concurrent mapping assigns an input position to each worker result;
unordered mapping emits each result as soon as it completes. Both use the
executor's capacity rather than creating an unbounded worker set.

## Source layout and compilation

The ASDF system loads the source files serially because later files use
private helpers defined by earlier files. The source is grouped by layer:

1. package and primitive wrappers;
2. conditions, deadlines, promises, and executors;
3. channels, selection, scopes, latches, and barriers;
4. stream stages and combinators.

The system's ASDF `:around-compile` hook applies the package's compilation
policy to its own files and restores the caller's policy afterward. It is kept
at the system boundary so loading this library does not alter compilation of
dependent systems.
