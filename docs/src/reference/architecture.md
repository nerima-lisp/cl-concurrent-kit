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
components use these wrappers for synchronization. `src/timeout.lisp` also
uses `sb-sys` and `sb-ext` directly for interrupt control and timers, and
`sb-thread:interrupt-thread` for delivery. `src/executor.lisp` directly uses
`sb-ext:compare-and-swap` to claim or cancel tasks.

`WITH-INTERRUPTIBLE-SCOPE` gives one invocation on the calling thread its own
interruption target. A request queues a transfer directly to that scope's
boundary. The transfer unwinds user cleanup without signaling a condition
inside the body. Only the boundary signals `OPERATION-INTERRUPTED`; body
condition handlers do not observe that condition. User cleanup can replace
the pending transfer with another non-local exit.

Completion and delivery can race. Their observable outcomes are:

| Ordering | Outcome |
|---|---|
| An ordinary request is delivered first | Unwind the body and user cleanup, then signal at the boundary. Repeated ordinary requests are ignored. |
| The body returns before any request is delivered | Preserve its return values and deactivate the scope so its queued callback cannot leave the boundary. |
| A delivered transfer is replaced by cleanup, then the body resumes and returns normally | The recorded delivery still causes a boundary condition; discard the body's values. |
| A force request arrives during user cleanup | Accept and enqueue it while the boundary remains live. Delivery can abandon the remaining cleanup and transfer to the boundary again. |
| Several force requests arrive before closure | Enqueue each accepted request; the latest accepted reason takes precedence if interruption is reported. |
| The wrapper's own cleanup has started, or the scope has exited | Ignore ordinary and force requests. They cannot affect a later invocation on the same thread. |
| The scope argument is `NIL` | Return `NIL` without requesting an interrupt. |
| A signal handler on the target thread requests interruption | The request must be its last action. Queueing does not guarantee return before delivery; interrupt-enabling work can deliver while the handler is still on the stack. |
| An outer scope is interrupted while an inner scope runs | Unwind the inner scope and its cleanup before reaching the outer boundary. |

An interruption delivered while the body is unwinding from `THROW` or an
error can replace that pending exit.

The boundary remains live throughout user cleanup, including cleanup started
by a prior interruption. Delivery records that interruption has started but
does not close the scope. Ordinary requests deduplicate against every earlier
accepted request, including a force request. Force requests can requeue while
unwinding and update the shared reason when accepted. The wrapper's own
cleanup closes the scope under the same mutex used for request acceptance,
before timer cleanup or draining. Every callback checks that lifetime before
transferring control.

Force can abandon blocked cleanup or retry after one replaced transfer. It
cannot stop cleanup that repeatedly replaces every transfer
with its own non-local exit or error.

Teardown drains pending scope callbacks before returning when the caller
permits interrupts. If the caller
encloses the entire scope in `WITHOUT-INTERRUPTS`, callbacks can remain pending
until that enclosing prohibition ends. They then see an inactive scope and
do nothing, even though the boundary has already exited.

SBCL can also delay delivery during garbage collection. Force requests respect
both delays. Callers must protect
resource acquisition and the state needed for cleanup against arbitrary
asynchronous exits.

`WITH-TIMEOUT` uses this same boundary with a timer requesting interruption.
It reports `OPERATION-TIMED-OUT` after unwinding.
`OPERATION-TIMED-OUT-OPERATION` reports the operation identifier;
`OPERATION-TIMED-OUT-TIMEOUT` reports the timeout in seconds.
A timer expiring during scope teardown cannot replace a completed result if
no timeout was previously delivered. If the caller prohibits interrupts for
the entire scope, the body can finish without the timeout firing at all.
The timer callback then either stays cancelled or sees a closed target and
does nothing when eventually delivered. Other blocking operations enforce their deadline by
returning from their wait and signaling the package's timeout condition.

The timer requests a direct transfer to the boundary rather than signaling
`SB-EXT:TIMEOUT` inside the body. A body handler for `SERIOUS-CONDITION`
therefore cannot catch expiry, and `WITH-TIMEOUT` supplies no `CONTINUE`
restart for it.

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
