# API reference

All symbols live in the `CL-CONCURRENT-KIT` package.

`:TIMEOUT` on this library's own blocking operations -- `AWAIT`, `SEND`,
`RECV`, `SELECT`'s `:TIMEOUT` clause, `AWAIT-LATCH`, `AWAIT-BARRIER`,
`SHUTDOWN-EXECUTOR`, `AWAIT-EXECUTOR-TERMINATION`, `WITH-EXECUTOR`'s
`SHUTDOWN-TIMEOUT`, `WITH-TASK-SCOPE`, `PROMISE-TIMEOUT`, and `WITH-TIMEOUT`
-- is a `cl-date-kit:duration`, or `NIL` for no deadline. The thin `sb-thread`
wrappers below (`JOIN-THREAD`, `CONDITION-WAIT`, `WAIT-ON-SEMAPHORE`) pass
their `:TIMEOUT` straight through to SBCL and so still take a raw number of
seconds, as does `OPERATION-TIMED-OUT-TIMEOUT`, which reports the elapsed
deadline as an exact rational.

## Threads

| Symbol | Description |
|---|---|
| `MAKE-THREAD` `(function &key name arguments)` | Run `function` on a new thread. |
| `CURRENT-THREAD` `()` | The calling thread. |
| `THREAD-NAME` `(thread)` | The thread's name. |
| `THREAD-ALIVE-P` `(thread)` | True while the thread's function is still running. |
| `JOIN-THREAD` `(thread &key default timeout)` | Block for the thread's return values. |

## Locks and condition variables

| Symbol | Description |
|---|---|
| `LOCK` | Type: what `MAKE-LOCK` returns and `WITH-LOCK-HELD` acquires. Declare a slot or variable with it -- `(or null cl-concurrent-kit:lock)` -- instead of naming `sb-thread:mutex`. |
| `MAKE-LOCK` `(&key name)` | Create a mutex. |
| `WITH-LOCK-HELD` `((lock) &body body)` | Hold `lock` for `body`'s dynamic extent. |
| `MAKE-CONDITION-VARIABLE` `(&key name)` | Create a condition variable. |
| `CONDITION-WAIT` `(cv lock &key timeout)` | Release `lock`, wait, reacquire. See its docstring for the timeout/lock-ownership contract. |
| `CONDITION-NOTIFY` `(cv)` | Wake one waiter. |
| `CONDITION-BROADCAST` `(cv)` | Wake every waiter. |

## Semaphores and atomic counters

| Symbol | Description |
|---|---|
| `MAKE-SEMAPHORE` `(&key name count)` | Create a counting semaphore. |
| `WAIT-ON-SEMAPHORE` `(semaphore &key timeout)` | Decrement, blocking while zero. |
| `SIGNAL-SEMAPHORE` `(semaphore &optional n)` | Increment by `n`. |
| `MAKE-ATOMIC-COUNTER` `(&optional initial-value)` | A lock-free non-negative counter. |
| `ATOMIC-COUNTER-VALUE` `(counter)` | Current value. |
| `ATOMIC-COUNTER-INCF` / `ATOMIC-COUNTER-DECF` `(counter &optional delta)` | Atomic add/subtract. |

## Preemptive timeouts

| Symbol | Description |
|---|---|
| `WITH-TIMEOUT` `(duration &body body)` | Macro: run `body` under a deadline of `duration`, a `cl-date-kit:duration`, returning its values. On expiry `body` is interrupted -- through SBCL's timer and `sb-thread:interrupt-thread` -- and `OPERATION-TIMED-OUT` is signaled with `:OPERATION :WITH-TIMEOUT`. `duration` `NIL`, or a zero or negative-length duration, means no deadline at all. This is the only *preemptive* deadline in the library; `WITH-TASK-SCOPE`'s cancellation is cooperative by design, and the two do not interchange -- see [Architecture](architecture.md#threading-primitives). |

Note the shape of `duration`: it is a bare form, as in `sb-ext:with-timeout`,
not a one-element list as in `bordeaux-threads:with-timeout`. Write
`(with-timeout (cl-date-kit:duration-of-seconds 5) ...)`, not
`(with-timeout ((cl-date-kit:duration-of-seconds 5)) ...)`.

## Promises and futures

| Symbol | Description |
|---|---|
| `MAKE-PROMISE` `()` | An unsettled promise. |
| `PROMISE-P` `(x)` | Type predicate. |
| `PROMISE-SETTLED-P` `(promise)` | True once settled. |
| `DELIVER` `(promise value)` | Settle successfully. |
| `DELIVER-ERROR` `(promise condition)` | Settle as failed. |
| `AWAIT` `(promise &key timeout)` | Block for the settled value, or re-signal its condition. |
| `PROMISE-THEN` `(promise on-fulfilled &optional on-rejected)` | Continuation-passing composition: register `on-fulfilled`/`on-rejected` and return a new `PROMISE` for whichever one runs, without blocking. See [Core concepts](../guide/core-concepts.md). |
| `PROMISE-RACE` `(promises)` | A `PROMISE` that settles the same way as whichever of `promises` (non-empty) settles first, via the same continuation-passing composition as `PROMISE-THEN`. |
| `FUTURE` `(&body body)` | Macro: spawn `body` on a thread, return its `PROMISE` immediately. |
| `PROMISE-ALL-SETTLED` `(promises)` | A `PROMISE` fulfilled, once every input has settled, with an ordered list of `PROMISE-SETTLEMENT` records; failures are represented rather than re-signaled. Never fails, even if some inputs do. Empty input yields `NIL`. |
| `PROMISE-SETTLEMENT` | Structure type returned by `PROMISE-ALL-SETTLED`. |
| `PROMISE-SETTLEMENT-P` `(x)` | Type predicate for settlement records. |
| `PROMISE-SETTLEMENT-STATE` `(settlement)` | `:FULFILLED` or `:FAILED`. |
| `PROMISE-SETTLEMENT-VALUE` `(settlement)` | Meaningful when `:FULFILLED`. |
| `PROMISE-SETTLEMENT-CONDITION` `(settlement)` | Meaningful when `:FAILED`. |

## Channels

| Symbol | Description |
|---|---|
| `MAKE-CHANNEL` `(&key buffer-size)` | `buffer-size` 0 (default) is unbuffered/rendezvous. |
| `CHANNEL-P` `(x)` | Type predicate. |
| `SEND` `(channel value &key timeout)` | Blocking send. |
| `RECV` `(channel &key timeout)` | Blocking receive; `(values nil nil)` when closed and drained. |
| `TRY-SEND` `(channel value)` | Non-blocking send. |
| `TRY-RECV` `(channel)` | Non-blocking receive; three return values (see docstring). |
| `CLOSE-CHANNEL` `(channel)` | Idempotent close. |
| `CHANNEL-CLOSED-P` `(channel)` | Advisory, lock-free query. |

## Select

| Symbol | Description |
|---|---|
| `SELECT` `(&body clauses)` | Macro: wait on several channel operations. Requires at least one `RECV` or `SEND` clause; channel and send-value forms are evaluated once, in clause order. `:DEFAULT` and `:TIMEOUT` are mutually exclusive. A bare `(RETURN)` in a clause body exits `SELECT`'s own internal loop, not a caller's enclosing one -- use a named `BLOCK`/`RETURN-FROM` instead. See [Core concepts](../guide/core-concepts.md). |

## Executors

| Symbol | Description |
|---|---|
| `MAKE-EXECUTOR` `(&key size name queue-capacity)` | A fixed-size worker pool. `QUEUE-CAPACITY` (default `NIL`, unbounded) bounds how many tasks may be queued at once. |
| `EXECUTOR-P` `(x)` | Type predicate. |
| `SUBMIT` `(executor thunk)` | Queue `thunk`, return a `PROMISE`. Never blocks: if `EXECUTOR` has shut down, or a bounded queue is full, `THUNK` never runs and the promise is rejected immediately with `EXECUTOR-SHUT-DOWN` or `EXECUTOR-QUEUE-FULL` respectively. |
| `TRY-SUBMIT` `(executor thunk)` | Like `SUBMIT`, but also returns whether `THUNK` was accepted as a second value, sparing an `AWAIT`/`HANDLER-CASE` just to find out. |
| `SHUTDOWN-EXECUTOR` `(executor &key wait cancel-pending timeout)` | Stop accepting work; with `cancel-pending`, reject queued tasks without running them. With `wait`, wait for workers to exit (via `AWAIT-EXECUTOR-TERMINATION`). `timeout` bounds that wait and signals `OPERATION-TIMED-OUT` if it expires; if called by an executor worker, it closes the queue but signals `EXECUTOR-SHUT-DOWN` instead of joining itself. |
| `AWAIT-EXECUTOR-TERMINATION` `(executor &key timeout)` | Block until every worker has exited. Does not itself request shutdown -- call `SHUTDOWN-EXECUTOR` first. Same worker-reentrancy and `:TIMEOUT` behavior as `SHUTDOWN-EXECUTOR`'s own `:WAIT`. |
| `WITH-EXECUTOR` `((var &key size name queue-capacity shutdown-timeout) &body body)` | Macro: bind `var` to a fresh executor for `body`'s extent, then shut it down and wait for pending work to finish (not cancel it) on any exit. |
| `EXECUTOR-MAP` `(executor function sequence &key max-in-flight)` | Apply `function` to each element on `executor`, up to `max-in-flight` concurrently (default: unbounded), and return an ordered list of results. Propagates the first in-order failure once every submitted call has settled. |
| `EXECUTOR-SHUTDOWN-P` `(executor)` | True once `SHUTDOWN-EXECUTOR` has been called. |
| `EXECUTOR-TERMINATED-P` `(executor)` | True once every worker thread has exited. |
| `EXECUTOR-QUEUE-CAPACITY` `(executor)` | The bound from `MAKE-EXECUTOR`'s `:QUEUE-CAPACITY`, or `NIL` if unbounded. |
| `EXECUTOR-QUEUE-DEPTH` `(executor)` | A snapshot of how many tasks are currently queued. |
| `EXECUTOR-HIGH-WATER-MARK` `(executor)` | The largest `EXECUTOR-QUEUE-DEPTH` has ever reached. |

## Structured concurrency

| Symbol | Description |
|---|---|
| `WITH-TASK-SCOPE` `((scope-var &key timeout) &body body)` | Macro: a nursery for `SPAWN`ed tasks. `TIMEOUT` (a `cl-date-kit:duration`) bounds only the wait for already-running children once the body itself has returned or signalled; on expiry every remaining child is cancelled cooperatively and `OPERATION-TIMED-OUT` is signaled with `:OPERATION :WITH-TASK-SCOPE`. That is the same condition type `WITH-TIMEOUT` signals, so a handler around a scope whose body uses `WITH-TIMEOUT` must read `OPERATION-TIMED-OUT-OPERATION` to tell which deadline expired. |
| `SPAWN` `(scope function &key executor)` | Start a tracked child task, return its `PROMISE`. With `EXECUTOR`, the child runs on that executor's worker pool instead of a dedicated thread. |
| `CHECK-CANCELLED` `(scope)` | Signal `TASK-CANCELLED` if `scope` has been cancelled. |

## Countdown latches

| Symbol | Description |
|---|---|
| `MAKE-COUNTDOWN-LATCH` `(count)` | A one-shot latch that opens once `COUNT-DOWN` has run `count` times (or immediately if `count` is zero). |
| `COUNTDOWN-LATCH-P` `(x)` | Type predicate. |
| `COUNTDOWN-LATCH-COUNT` `(latch)` | The remaining count. |
| `COUNT-DOWN` `(latch &optional decrement)` | Reduce the count by `decrement` (default 1); signals `LATCH-COUNT-UNDERFLOW` if that would go below zero. |
| `AWAIT-LATCH` `(latch &key timeout scope)` | Block until `latch` opens. With `SCOPE` (passed explicitly, like `SPAWN`'s own `SCOPE`), also unblocks and signals `TASK-CANCELLED` if `SCOPE` is cancelled first. |

## Cyclic barriers

| Symbol | Description |
|---|---|
| `MAKE-BARRIER` `(parties)` | A reusable barrier releasing once `parties` callers have all arrived. |
| `BARRIER-P` `(x)` | Type predicate. |
| `BARRIER-PARTIES` `(barrier)` | The fixed party count. |
| `BARRIER-NUMBER-WAITING` `(barrier)` | A snapshot of arrivals in the current generation. |
| `BARRIER-BROKEN-P` `(barrier)` | True once `barrier` rejects arrivals until `RESET-BARRIER`. |
| `AWAIT-BARRIER` `(barrier &key timeout scope)` | Arrive and block for the rest of the current generation's parties; returns 0 to the last arrival, a positive index to the others. A timeout or cancelled `SCOPE` breaks the generation for everyone still waiting. |
| `RESET-BARRIER` `(barrier)` | Abandon the current generation (its waiters see `BARRIER-BROKEN`) and permit a fresh one. |

## Reactive streams

Stages built on channels; every one takes an optional `:SCOPE`, passed
explicitly like `SPAWN`'s own `SCOPE` (a tracked child, cooperatively
cancellable between values -- see [Architecture](architecture.md)), and an
optional `:EXECUTOR`. See [Core concepts](../guide/core-concepts.md) for the shared stage
contract (output ownership, closing, and completion promises).

| Symbol | Description |
|---|---|
| `CHANNEL-PRODUCER` `((emit &key buffer-size scope executor) &body body)` | Macro: an async source whose `body` sends values through the lexical function `emit`. Returns the output channel and a completion promise. |
| `CHANNEL-FROM-SEQUENCE` `(sequence &key buffer-size scope executor)` | A finite source over a snapshot of `sequence`. |
| `CHANNEL-MAP` `(function input &key buffer-size scope executor)` | Apply `function` to every value. |
| `CHANNEL-KEEP` `(function input &key buffer-size scope executor)` | Apply `function`, forward only non-`NIL` results. |
| `CHANNEL-FILTER` `(predicate input &key buffer-size scope executor)` | Forward values `predicate` accepts. |
| `CHANNEL-DISTINCT-UNTIL-CHANGED` `(input &key test key buffer-size scope executor)` | Forward the first value and any value whose `key` differs from the prior one. |
| `CHANNEL-DEBOUNCE` `(interval input &key buffer-size scope executor)` | Emit the latest value once `interval` seconds pass with nothing newer. |
| `CHANNEL-THROTTLE` `(interval input &key buffer-size scope executor)` | Emit the first value per `interval`-second window; discard the rest of the window. |
| `CHANNEL-FLAT-MAP` `(function input &key buffer-size scope executor)` | Apply `function` (returning a sequence) and forward every element, in order. |
| `CHANNEL-SCAN` `(function initial-value input &key buffer-size scope executor)` | Emit each successive accumulator value; the initial value itself is not emitted. |
| `CHANNEL-REDUCE` `(function initial-value input &key scope executor)` | Resolve to the final accumulator once `input` closes. |
| `CHANNEL-COLLECT` `(input &key scope executor)` | Resolve to a list of every value, in order. |
| `CHANNEL-EACH` `(function input &key scope executor)` | Run `function` on every value; resolve to `NIL`. |
| `CHANNEL-SOME` `(predicate input &key scope executor)` | Resolve to the first truthy `predicate` result, or `NIL`. |
| `CHANNEL-EVERY` `(predicate input &key scope executor)` | Resolve to `T` unless `predicate` is false for some value. |
| `CHANNEL-FIND` `(predicate input &key scope executor)` | Resolve to the first matching value, or `NIL`. |
| `CHANNEL-BROADCAST` `(input count &key buffer-size scope executor)` | Replicate every value to `count` fresh output channels; returns a list of channels. |
| `CHANNEL-TAKE` `(count input &key buffer-size scope executor)` | Forward at most `count` values; `input` stays open. |
| `CHANNEL-DROP` `(count input &key buffer-size scope executor)` | Discard the first `count` values, forward the rest. |
| `CHANNEL-TAKE-WHILE` `(predicate input &key buffer-size scope executor)` | Forward the matching prefix; consumes (without forwarding) the first non-match. |
| `CHANNEL-BATCH` `(size input &key buffer-size emit-partial scope executor)` | Group values into lists of `size`; `emit-partial` controls a final short batch. |
| `CHANNEL-PARTITION-BY` `(key input &key buffer-size scope executor)` | Group consecutive values sharing an `EQL` key into lists. |
| `CHANNEL-MAP-CONCURRENT` `(parallelism function input &key buffer-size scope executor)` | Apply `function` across up to `parallelism` workers, preserving input order in the output. |
| `CHANNEL-MAP-UNORDERED` `(parallelism function input &key buffer-size scope executor)` | Like `CHANNEL-MAP-CONCURRENT`, but emits in completion order. |
| `CHANNEL-MERGE` `(channels &key buffer-size scope executor)` | Fairly interleave several channels into one; closes once every input is closed and drained. |
| `CHANNEL-ZIP` `(channels &key buffer-size scope executor)` | Combine one value from every input into ordered tuples; stops at the shortest input. |
| `CHANNEL-CONCAT` `(channels &key buffer-size scope executor)` | Drain each channel fully, in order, before the next. |
| `CHANNEL-CONCAT-MAP` `(function input &key buffer-size scope executor)` | Apply `function` (returning a channel) and drain each result fully before the next value. |
| `CHANNEL-MERGE-MAP` `(function input &key parallelism buffer-size scope executor)` | Apply `function` (returning a channel) and fairly merge up to `parallelism` of the results concurrently. |
| `CHANNEL-SWITCH-MAP` `(function input &key buffer-size scope executor)` | Apply `function` (returning a channel) and forward only the most recently returned one. |

## Conditions

| Symbol | Base | Description |
|---|---|---|
| `CL-CONCURRENT-KIT-ERROR` | `ERROR` | Base condition for the whole library. |
| `OPERATION-TIMED-OUT` | `CL-CONCURRENT-KIT-ERROR` | A timeout-capable operation, including `AWAIT`, `SEND`, `RECV`, `SELECT`, executor shutdown, scope cleanup, or a `WITH-TIMEOUT` body, exhausted its deadline. Readers: `OPERATION-TIMED-OUT-OPERATION`, `OPERATION-TIMED-OUT-TIMEOUT`. |
| `PROMISE-ALREADY-FULFILLED` | `CL-CONCURRENT-KIT-ERROR` | `DELIVER`/`DELIVER-ERROR`/`CANCEL-PROMISE` called on an already-settled promise. Reader: `PROMISE-ALREADY-FULFILLED-PROMISE`. |
| `CHANNEL-CLOSED` | `CL-CONCURRENT-KIT-ERROR` | `SEND`/`TRY-SEND` after close. Reader: `CHANNEL-CLOSED-CHANNEL`. |
| `EXECUTOR-SHUT-DOWN` | `CL-CONCURRENT-KIT-ERROR` | A submission was rejected or cancelled by executor shutdown, or an executor worker called `SHUTDOWN-EXECUTOR`/`AWAIT-EXECUTOR-TERMINATION` and therefore could not join itself. Reader: `EXECUTOR-SHUT-DOWN-EXECUTOR`. |
| `EXECUTOR-QUEUE-FULL` | `CL-CONCURRENT-KIT-ERROR` | `SUBMIT`/`TRY-SUBMIT` rejected by a bounded executor's full queue. Readers: `EXECUTOR-QUEUE-FULL-EXECUTOR`, `EXECUTOR-QUEUE-FULL-CAPACITY`. |
| `TASK-CANCELLED` | `CL-CONCURRENT-KIT-ERROR` | Signaled by `CHECK-CANCELLED`, or by `AWAIT-LATCH`/`AWAIT-BARRIER` when their `:SCOPE` is cancelled. Reader: `TASK-CANCELLED-SCOPE`. |
| `SCOPE-ERROR` | `CL-CONCURRENT-KIT-ERROR` | One or more `SPAWN`ed tasks failed. Reader: `SCOPE-ERROR-CAUSES`. |
| `LATCH-COUNT-UNDERFLOW` | `CL-CONCURRENT-KIT-ERROR` | `COUNT-DOWN` would take a latch below zero. Readers: `LATCH-COUNT-UNDERFLOW-LATCH`, `LATCH-COUNT-UNDERFLOW-COUNT`, `LATCH-COUNT-UNDERFLOW-DECREMENT`. |
| `BARRIER-BROKEN` | `CL-CONCURRENT-KIT-ERROR` | `AWAIT-BARRIER` on a barrier broken by a timeout, a cancelled scope, or `RESET-BARRIER`. Reader: `BARRIER-BROKEN-BARRIER`. |
| `PROMISE-CANCELLED` | `CL-CONCURRENT-KIT-ERROR` | `AWAIT` on a promise `CANCEL-PROMISE` settled. Readers: `PROMISE-CANCELLED-PROMISE`, `PROMISE-CANCELLED-REASON`. |
| `PROMISE-EMPTY-INPUT` | `CL-CONCURRENT-KIT-ERROR` | `PROMISE-ANY` (or `PROMISE-RACE`) called with no promises. Reader: `PROMISE-EMPTY-INPUT-OPERATION`. |
| `PROMISE-ALL-FAILED` | `CL-CONCURRENT-KIT-ERROR` | `PROMISE-ANY` when every input failed. Reader: `PROMISE-ALL-FAILED-CAUSES`. |
