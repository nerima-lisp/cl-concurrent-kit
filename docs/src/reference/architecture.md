# Architecture

## Platform and dependencies

The library targets SBCL and wraps `sb-thread` through the small interface in
`src/primitives.lisp`. It depends on CL-BOUNDARY-KIT for monotonic clocks and
CL-DATE-KIT for duration values. Public timeout arguments use
`CL-DATE-KIT:DURATION`; callers can construct one with
`CL-DATE-KIT:DURATION-OF-SECONDS`, `-MILLIS`, `-MICROS`, or `-NANOS`.

The special variable `*CLOCK*` contains the clock used for deadline
arithmetic. Tests can bind it to a fake clock from CL-BOUNDARY-KIT.

## Threading primitives

`src/primitives.lisp` defines the package's low-level protocol: threads,
mutexes, condition variables, semaphores, and atomic counters. Higher-level
code uses these wrappers instead of depending on implementation-specific
objects throughout the rest of the system.

`src/timeout.lisp` derives one monotonic deadline from a duration and uses it
for the operation. `WITH-TIMEOUT` additionally interrupts the body when its
deadline expires. Operations that wait on a condition variable return to the
caller on timeout so they can signal the package's timeout condition.

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
