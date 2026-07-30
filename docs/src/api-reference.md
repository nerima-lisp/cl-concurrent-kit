# API reference

All symbols live in the `CL-CONCURRENT-KIT` package.

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

## Promises and futures

| Symbol | Description |
|---|---|
| `MAKE-PROMISE` `()` | An unsettled promise. |
| `PROMISE-P` `(x)` | Type predicate. |
| `PROMISE-SETTLED-P` `(promise)` | True once settled. |
| `DELIVER` `(promise value)` | Settle successfully. |
| `DELIVER-ERROR` `(promise condition)` | Settle as failed. |
| `AWAIT` `(promise &key timeout)` | Block for the settled value, or re-signal its condition. |
| `FUTURE` `(&body body)` | Macro: spawn `body` on a thread, return its `PROMISE` immediately. |
| `PROMISE-ALL-SETTLED` `(promises)` | Fulfill with ordered settlement records after every input settles; failures are represented rather than re-signaled. Empty input yields `NIL`. |
| `PROMISE-SETTLEMENT` | Structure type returned by `PROMISE-ALL-SETTLED`. |
| `PROMISE-SETTLEMENT-P` `(x)` | Type predicate for settlement records. |
| `PROMISE-SETTLEMENT-STATE` / `-VALUE` / `-CONDITION` `(settlement)` | Access the `:FULFILLED`/`:FAILED` state and its value or condition. |

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
| `SELECT` `(&body clauses)` | Macro: wait on several channel operations. Requires at least one `RECV` or `SEND` clause; channel and send-value forms are evaluated once, in clause order. `:DEFAULT` and `:TIMEOUT` are mutually exclusive. See [Core concepts](concepts.md). |

## Executors

| Symbol | Description |
|---|---|
| `MAKE-EXECUTOR` `(&key size name)` | A fixed-size worker pool. |
| `EXECUTOR-P` `(x)` | Type predicate. |
| `SUBMIT` `(executor thunk)` | Queue `thunk`, return a `PROMISE`; after shutdown the promise fails with `EXECUTOR-SHUT-DOWN`. |
| `SHUTDOWN-EXECUTOR` `(executor &key wait cancel-pending timeout)` | Stop accepting work; with `cancel-pending`, reject queued tasks without running them. With `wait`, wait for workers to exit. `timeout` bounds the entire join phase and signals `OPERATION-TIMED-OUT` if it expires; if called by an executor worker, it closes the queue but signals `EXECUTOR-SHUT-DOWN` instead of joining itself. |

## Structured concurrency

| Symbol | Description |
|---|---|
| `WITH-TASK-SCOPE` `((scope-var &key timeout) &body body)` | Macro: a nursery for `SPAWN`ed tasks. `timeout` bounds the cleanup wait for tracked children and signals `OPERATION-TIMED-OUT` after cancelling them. |
| `SPAWN` `(scope function &key executor)` | Start a tracked child task, optionally on a shared executor, and return its `PROMISE`. |
| `CHECK-CANCELLED` `(scope)` | Signal `TASK-CANCELLED` if `scope` has been cancelled. |

## Conditions

| Symbol | Base | Description |
|---|---|---|
| `CL-CONCURRENT-KIT-ERROR` | `ERROR` | Base condition for the whole library. |
| `OPERATION-TIMED-OUT` | `CL-CONCURRENT-KIT-ERROR` | A timeout-capable operation, including `AWAIT`, `SEND`, `RECV`, `SELECT`, executor shutdown, or scope cleanup, exhausted its deadline. Readers: `OPERATION-TIMED-OUT-OPERATION`, `OPERATION-TIMED-OUT-TIMEOUT`. |
| `PROMISE-ALREADY-FULFILLED` | `CL-CONCURRENT-KIT-ERROR` | `DELIVER`/`DELIVER-ERROR` called twice. Reader: `PROMISE-ALREADY-FULFILLED-PROMISE`. |
| `CHANNEL-CLOSED` | `CL-CONCURRENT-KIT-ERROR` | `SEND`/`TRY-SEND` after close. Reader: `CHANNEL-CLOSED-CHANNEL`. |
| `EXECUTOR-SHUT-DOWN` | `CL-CONCURRENT-KIT-ERROR` | A submission was rejected or cancelled by executor shutdown, or an executor worker called `SHUTDOWN-EXECUTOR` with `:WAIT T` and therefore could not join itself. Reader: `EXECUTOR-SHUT-DOWN-EXECUTOR`. |
| `TASK-CANCELLED` | `CL-CONCURRENT-KIT-ERROR` | Signaled by `CHECK-CANCELLED`. Reader: `TASK-CANCELLED-SCOPE`. |
| `SCOPE-ERROR` | `CL-CONCURRENT-KIT-ERROR` | One or more `SPAWN`ed tasks failed. Reader: `SCOPE-ERROR-CAUSES`. |
