# Architecture

## Why SBCL only, wrapping sb-thread directly

[nerima-lisp's coding standard](https://github.com/nerima-lisp/.github/blob/main/CODING_STANDARD.md)
targets SBCL exclusively and treats `sb-thread` as the default choice over
adding bordeaux-threads as an external dependency: every other repository in
the org that needs threads already calls `sb-thread` directly. This project
follows that precedent instead of reintroducing the portability layer it
would otherwise have depended on -- see `src/primitives.lisp` for the thin
wrapper this produces.

## Dependencies: SBCL and sb-thread only, nothing else at runtime

The same [coding standard](https://github.com/nerima-lisp/.github/blob/main/CODING_STANDARD.md)
that settles SBCL-vs-portability-layer above settles this too: prefer what
SBCL already ships over adding a dependency for it, org-wide. This project's
own `.asd` `:description` states the consequence directly -- "Dependency-free,
SBCL-only" -- and `:depends-on ()` on `cl-concurrent-kit` itself (as opposed
to `cl-concurrent-kit/test`, which depends on `cl-weave`) is that sentence
enforced, not just claimed. Three nerima-lisp packages are already used
elsewhere in this repository, deliberately kept out of that runtime
dependency list: `cl-weave` for the test suite (`cl-concurrent-kit/test`'s
own `:depends-on`, never `cl-concurrent-kit`'s), `cl-cli` for
`benchmarks/run-benchmarks.lisp`'s argument parsing (reached only through
`flake.nix`'s `CL_SOURCE_REGISTRY` for that one script, the same way
`cl-weave` is), and `cl-nix-forge` for `flake.nix`'s own packaging --
none reachable from a consumer that only loads the library. Adding a
further nerima-lisp package as a *runtime* dependency -- `cl-log-kit`, say,
for the one `(format *error-output* ...)` call in `src/executor.lisp`'s
worker loop -- would contradict that `:description` outright for a single
call site, the textbook shape of the adapter this project's own
instructions ask not to build. Benchmark tooling and the test suite face no
such objection: neither ships to, nor is reachable from, a consumer that
only depends on `cl-concurrent-kit` itself.

The rest of the org's catalog (checked against
[github.com/orgs/nerima-lisp/repositories](https://github.com/orgs/nerima-lisp/repositories)
as of v0.3.0) fares no better against that same test: `cl-json-kit`,
`cl-regex-kit`, `cl-codec-kit`, `cl-parser-kit`, `cl-date-kit`,
`cl-tty-kit`, and `cl-host-kit` all answer a data-format, text, or
host-environment need this package -- concurrency primitives over
`sb-thread` alone -- has no call site for at all; adopting one would be a
dependency in search of a use, not a use in search of a dependency.
`cl-boundary-kit` and `cl-dataflow` are the closest in *spirit* (explicit
boundary/effect abstractions, composable computation graphs) but overlap
this project's own domain closely enough that depending on either would
mean wrapping their abstractions around this package's -- the adapter this
architecture deliberately avoids -- rather than composing with them as a
consumer. `cl-cc`, `nshell`, `loom`, and the `cl-cc-*` compiler-internals
repositories are a different domain (a self-hosting compiler, a shell, a
terminal editor) with no natural connection to this one at all.

## No backward-compatibility surface to eliminate

A codebase carries backward-compatibility weight when a later API replaces
an earlier one and both must keep working -- a deprecated alias, a
compatibility shim, a `#+old-sbcl` branch preserved past its last caller.
Every release so far (v0.1.0 through v0.3.0) has changed public symbols'
shapes outright rather than deprecating them -- `%CHANNEL-DEQUEUE` and the
ring-buffer `CHANNEL`/`%WORK-QUEUE` internals replaced the FIFO-backed ones
wholesale in v0.3.0, for instance, with no transitional alias kept alongside
either. Grepping the tree confirms the result: zero matches across `src/`,
`t/`, and the `.asd` for `deprecated`, `legacy`, `obsolete`, `backward-compat`,
or `shim`, in any casing -- re-verified as part of the v0.3.0 refactor, not
just inherited from an earlier audit. The absence is the intended state, not
a gap -- keep it that way by deleting rather than deprecating when a public
symbol's shape changes, exactly as `cl-concurrent-kit.asd`'s `:version
"0.3.0"` (no `1.x` compatibility promise yet) allows.

## The CONDITION-WAIT timeout contract

`SB-THREAD:CONDITION-WAIT` releases the mutex while waiting and reacquires it
before every return, including when `:TIMEOUT` returns `NIL`. Code must loop
after spurious wakeups and inspect lock-protected state while holding the
mutex after every wakeup. `src/primitives.lisp`'s `%WAIT-UNTIL` relies on that
ownership contract while computing one absolute deadline, so repeated wakeups
cannot extend the requested timeout.

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
semaphore in addition to whichever of the channel's own send/recv/rendezvous
condition variables actually changed (`%CHANNEL-NOTIFY`); each waiter carries
an interest bitmask so a state transition wakes only the `SELECT` calls that
can actually retry against it, not every waiter on the channel. `SELECT`'s
loop tries every clause non-blockingly (via `TRY-SEND`/`TRY-RECV`) in
declaration order and chooses the first ready operation -- deterministic
priority, so the first clause written wins ties, rather than randomizing for
fairness. The loop only sleeps on its semaphore -- with a computed remaining
timeout, if any -- when nothing was ready. `UNWIND-PROTECT` guarantees the
waiter is removed from every channel before `SELECT` returns, however it
returns.

Because the clauses are available at macroexpansion time, `SELECT` emits these
probes directly instead of allocating a runtime operation vector and
dispatching its selected index. This changes only the ready-path overhead; the
registration, retry, and cleanup protocol remains the same.

`%EXPAND-SELECT` runs every clause's non-blocking probe once *before*
`MAKE-SEMAPHORE` or `%CHANNEL-ADD-WAITER` ever runs. A `SELECT` whose first
clause is already ready -- overwhelmingly the common case for a channel with a
buffered value already waiting -- never allocates a waiter semaphore or enters
the `UNWIND-PROTECT` at all; only a call that finds nothing ready pays for
registration, and the same probes run again inside the wait loop once
registered.

## CHANNEL's queue is a ring buffer, not a linked list

`CHANNEL` and the executor's internal work queue each hold their values in a
preallocated `SIMPLE-ARRAY` addressed by `HEAD`/`TAIL` indices that wrap
modulo the array's length, rather than in a cons-based or intrusive
linked-list queue. Enqueuing and dequeuing are array writes, not allocations;
the executor's queue additionally doubles its buffer's length (copying live
entries into a fresh array) the one time it fills, rather than growing one
cell at a time. An unbuffered `CHANNEL`'s rendezvous -- `SEND` waiting for its
own value to actually be taken back out -- is a `RENDEZVOUS-GENERATION`
counter `RECV` increments on every dequeue, instead of a per-message struct
`SEND` allocates just to flip its own `RECEIVED-P` flag back to `SEND`.

## Waiter dispatch is bucketed by interest, not scanned

A channel can accumulate many `SELECT` calls waiting on it at once, each
interested in a different subset of {send, recv, rendezvous} events
(`%CHANNEL-ADD-WAITER`'s `INTERESTS` bitmask, above). Rather than one
`MAPHASH` over every registered waiter on each notification -- work
proportional to total waiters regardless of how many actually care --
`%CHANNEL-NOTIFY-WAITERS` keeps one hash-table per distinct interest
combination (an 8-slot array, since three event bits combine into eight
subsets) plus a per-bit reference count and an aggregate interest mask, so a
notification that nothing is interested in returns immediately, and one that
something is interested in only walks the bucket(s) that actual interest.

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

Cancellation is cooperative rather than forced -- not for want of a
mechanism, which `WITH-TIMEOUT` has and the next section explains, but because
forcing it would cost the guarantee a scope exists to make. `CHECK-CANCELLED`
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

`SPAWN-CHILD` itself is only the two-way dispatch: `%SPAWN-EXECUTOR-CHILD`
queues on an `EXECUTOR` and wires its cancellation through
`%EXECUTOR-TASK-CANCEL` so a still-queued task reacts to scope cancellation
exactly as a running one does; `%SPAWN-THREAD-CHILD` runs on a dedicated
thread via `%DELIVER-ON-THREAD` (`src/promise.lisp`), the same
run-a-thunk-on-a-thread-and-settle-a-promise primitive `FUTURE` uses.

## Preemptive WITH-TIMEOUT, cooperative scopes

Every `:TIMEOUT` in this library other than `WITH-TIMEOUT`'s bounds a wait
cl-concurrent-kit implements itself -- a `CONDITION-WAIT` inside
`%WAIT-UNTIL`, a semaphore inside `SELECT` -- and such a deadline needs no
mechanism beyond declining to wait any longer. An arbitrary body is the case
that shape cannot reach: it may be computing, or blocked in a read this
library never sees.

`src/timeout.lisp`'s `WITH-TIMEOUT` is the one place that reaches for the
other mechanism. `SB-EXT:WITH-TIMEOUT` schedules a timer that interrupts the
running thread, which really does bound an arbitrary body; what it does not do
is speak this library's vocabulary. `SB-EXT:TIMEOUT` is a `SERIOUS-CONDITION`
but deliberately *not* an `ERROR`, so neither a caller's own
`(handler-case ... (error ...))` nor the
`(handler-case ... (cl-concurrent-kit-error ...))` this library promises
catches it. `WITH-TIMEOUT` translates it into `OPERATION-TIMED-OUT`, the same
condition every other deadline here signals, so `sb-ext` never appears in a
caller's handler clauses.

The translation discriminates by deadline rather than by catching every
`SB-EXT:TIMEOUT` in sight. Each `WITH-TIMEOUT` records the instant its own
deadline falls, and its handler claims a `SB-EXT:TIMEOUT` only once that
instant has actually arrived; anything earlier belongs to a timeout the body
itself established -- a nested `WITH-TIMEOUT`, or a direct
`SB-EXT:WITH-TIMEOUT` in the body -- and is declined so it keeps propagating
to whoever did establish it. Without that test, an outer form would report its
own generous budget as the one that ran out whenever an inner, tighter one
expired. The deadline is computed *before* the timer is scheduled, so it can
only be earlier than the instant that timer fires and a form can never fail to
recognize its own expiry over a rounding margin.

This is deliberately *not* how `WITH-TASK-SCOPE` cancels. An asynchronous
interrupt lands between two arbitrary instructions, so it can unwind a task
whose `UNWIND-PROTECT` has not yet recorded the resource its cleanup would
release -- `SB-EXT:WITH-TIMEOUT`'s own docstring works that hazard through at
length. A scope exists to guarantee that every child it started has finished
and been accounted for, and that guarantee is worth more than reclaiming a
task a few moments sooner. Bound work that is safe to abandon at an arbitrary
point with `WITH-TIMEOUT`; for work that owns a resource, use a scope and
`CHECK-CANCELLED`.

## A generic waker joins cancellation to arbitrary blocked waits

`CHECK-CANCELLED` covers a task that polls for cancellation between steps,
but `AWAIT-LATCH`, `AWAIT-BARRIER`, and every reactive stream stage instead
block on their *own* condition variable -- one cancellation cannot signal
directly. `src/scope-state.lisp` generalizes `%SCOPE-CHILD-CANCEL`'s existing
per-child callback into a `WAKERS` hash-table on `TASK-SCOPE` itself:
`%SCOPE-ADD-WAKER` registers an arbitrary zero-argument callback (calling it
immediately, instead, if the scope is already cancelled), and `%SCOPE-CANCEL`
invokes every registered waker exactly once, outside the scope's own lock,
the same pass it uses to invoke every child's cancel callback. A blocked
`AWAIT-LATCH` registers a waker that signals its own condition variable; a
stream stage registers one that closes its output channel. Both unregister
via `%SCOPE-REMOVE-WAKER` in an `UNWIND-PROTECT`, so a wait that finishes
before cancellation leaves nothing behind to fire later.

## %EXPAND-SELECT split into parse/bind/probe

`SELECT`'s own macroexpander, `%EXPAND-SELECT` (`src/select.lisp`), used to be
one function doing clause-parsing, validation, gensym-binding construction,
and code generation all at once. It is now three named steps --
`%SELECT-PARSE-CLAUSES` (turn raw clauses into an ordered operation list, a
`:DEFAULT`/`:TIMEOUT` pair, and their mutual-exclusion checks),
`%SELECT-BINDINGS` (one gensym per channel, and per value for a `:SEND`), and
`%SELECT-PROBE-FORMS` (the non-blocking `TRY-RECV`/`TRY-SEND` probe each
clause becomes) -- with `%EXPAND-SELECT` itself left as the orchestration that
calls them and assembles the final expansion.

All four still live inside the same
`(EVAL-WHEN (...) (LET ((SB-EXT:*EVALUATOR-MODE* :INTERPRET)) (EVAL '(PROGN ...))))`
wrapper as before, and that is deliberate: forcing this code to be
*interpreted* rather than compiled is what avoids an SBCL 2.6.0
constraint-propagation pathology related to, but distinct from, the one
`cl-concurrent-kit.asd`'s own `SPEED 0` comment documents -- that one is
`SPAWN-CHILD`'s, this one is `%EXPAND-SELECT`'s own shape. Splitting the
function for readability could not be allowed to also move any of this code
from interpreted to compiled, so the split stayed inside the one `EVAL`'d
`PROGN` rather than becoming ordinary top-level `DEFUN`s.

## The high-complexity readability pass

A byte-span ranking of every `DEFUN`/`DEFMACRO` in `src/` once put nine
functions well above the rest. Each was read individually and either
genuinely restructured or deliberately left alone, on a case-by-case
judgment rather than a mechanical "split everything over N bytes" rule:

- `CHANNEL-MAP-CONCURRENT` and `CHANNEL-MAP-UNORDERED`
  (`src/stream-map-concurrent.lisp`) each had one dispatch loop mixing job
  submission, result collection, and (for the ordered variant) output
  reordering inline. Both now name their two or three concerns as `LABELS`
  functions (`FILL-JOBS`, `COLLECT-ONE-RESULT`, and
  `CHANNEL-MAP-CONCURRENT`'s own `DRAIN-READY-OUTPUTS`), leaving the
  top-level loop as a short, named sequence instead of a nested
  `LOOP`/`COND`/`DESTRUCTURING-BIND`.
- `CHANNEL-DEBOUNCE` (`src/stream.lisp`) had its two states -- waiting for a
  first value, versus waiting out quiet time or flushing one -- written as
  the two branches of one inline `IF` inside `SELECT`. They are now
  `WAIT-FOR-FIRST-VALUE` and `WAIT-FOR-QUIET-OR-FLUSH`, named functions
  the loop dispatches between.
- `AWAIT-BARRIER` (`src/latch.lisp`) had "I am the last party to arrive" and
  "I must wait" as an inline `IF`'s two branches; they are now
  `RELEASE-AS-LAST-PARTY` and `WAIT-FOR-RELEASE`.
- `PROMISE-ALL` and `PROMISE-ANY` (`src/promise-combinators.lisp`) each
  repeated the same three-step "store the observer, subscribe it, unsubscribe
  it again if the race was already decided by the time `%OBSERVE-PROMISE`
  returned" around their own differing observer closures. `%WITH-RACE-CLEANUP`
  -- the macro both already shared for `DECIDED-P` and
  `STOP-OBSERVING-OTHERS` -- gained a third anaphoric local function,
  `REGISTER-OBSERVER`, so neither function repeats it.
- `PROMISE-ALL-SETTLED` had its `STATE`/`OUTCOME` pair to `PROMISE-SETTLEMENT`
  mapping written inline inside the per-input observer; `%PROMISE-SETTLEMENT-FOR`
  now names that mapping as its own function, and `RECORD-SETTLEMENT` names
  the per-input registration step.
- `PROMISE-TIMEOUT` had its race's two sides -- react to `PROMISE` settling,
  react to the timer firing first -- as two inline `LAMBDA`s; they are now
  `ON-PROMISE-SETTLED` and `RUN-TIMER`.
- `WITH-TASK-SCOPE` (`src/scope.lisp`) had an await-then-cancel-on-timeout
  `HANDLER-CASE` inline in its expansion, alongside the macro's own
  close-then-maybe-cancel-on-abnormal-exit logic. That `HANDLER-CASE` never
  touches `BODY` and so never needed to run inline; it is now
  `%SCOPE-AWAIT-CHILDREN-OR-CANCEL`, an ordinary function in
  `src/scope-state.lisp` alongside `%SCOPE-AWAIT-CHILDREN` itself. The
  macro's own expansion shrinks to the two concerns that truly require
  running inline with `BODY`: closing the scope and conditionally cancelling
  it.
- `WITH-TIMEOUT`'s `%CALL-WITH-TIMEOUT` (`src/timeout.lisp`) is the one
  left unchanged. Its `HANDLER-BIND` clause is already the minimal shape
  SB-EXT:TIMEOUT's translation needs -- a three-line predicate that must stay
  lexically inside `(BLOCK ATTEMPT ...)` because it calls `RETURN-FROM
  ATTEMPT`. Naming it as a separate function would either move that
  `RETURN-FROM` somewhere it can no longer reach `ATTEMPT`, or add a thin
  wrapper around it purely to satisfy a byte-count ranking -- renaming the
  code without clarifying it.

## Variable-arity SELECT for stream fan-in

`SELECT` (`src/select.lisp`) is a macro: its clause count and shape must be
known at macroexpansion time, which is exactly wrong for `CHANNEL-MERGE`,
`CHANNEL-ZIP`, and similar stages that fan in from a runtime-determined list
of channels. `src/stream-fan-in.lisp`'s `%RUN-DYNAMIC-SELECT` reimplements
`SELECT`'s registration/retry/cleanup protocol as an ordinary function over a
list of `(CHANNEL . HANDLER)` conses instead: register one waiter semaphore
on every channel, loop trying each clause non-blockingly, sleep on the
semaphore between attempts, and remove the waiter from every channel in an
`UNWIND-PROTECT` on the way out -- the same shape as `SELECT` itself, deliberately,
just driven by a runtime list rather than clauses baked into the expansion.

A `SELECT` clause body is spliced directly inside `SELECT`'s own probing
`LOOP`, which -- like any `LOOP` -- establishes its own implicit block named
`NIL`. A bare `(RETURN)` written inside a clause body exits *that* loop, not
an enclosing one the caller happens to have of their own; `CHANNEL-DEBOUNCE`
needed an explicit named `BLOCK`/`RETURN-FROM` around its own outer loop for
exactly this reason. See `src/select.lisp`'s own docstring for the full
explanation.

## One lock per struct, one macro per lock

`CHANNEL`, `%WORK-QUEUE`, and `TASK-SCOPE` each guard their own mutable state
with a lock living in a slot of the same struct. Rather than every caller
spelling out `(WITH-LOCK-HELD ((CHANNEL-LOCK CHANNEL)) ...)` by hand,
`%WITH-CHANNEL-LOCK`, `%WITH-WORK-QUEUE-LOCK`, and `%WITH-SCOPE-LOCK` (one
per file, next to the struct they wrap) name the operation once each --
"hold this object's own lock" -- and every operation on that struct expands
through it instead.

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

The other half of that arithmetic -- an absolute deadline back down to
"seconds remaining, floored at zero" for whatever blocking primitive is
about to wait on it -- used to be written out in full at each of its three
call sites: `%WAIT-UNTIL`'s own wait, `SELECT`'s expansion, and
`AWAIT-EXECUTOR-TERMINATION`'s `JOIN-THREAD` loop. `src/primitives.lisp`'s
`%SECONDS-UNTIL-DEADLINE` is that arithmetic written once, `%DEADLINE-FROM-TIMEOUT`'s
inverse, so all three now share one place to get the flooring-at-zero
behavior right instead of three copies to keep in sync.

## One consume-loop shape, one macro

`CHANNEL-REDUCE`, `CHANNEL-COLLECT`, `CHANNEL-EACH`, `CHANNEL-SOME`,
`CHANNEL-EVERY`, and `CHANNEL-FIND` (`src/stream.lisp`); `CHANNEL-BROADCAST`,
`CHANNEL-TAKE`, `CHANNEL-TAKE-WHILE`, and `CHANNEL-BATCH`
(`src/stream-fan-out.lisp`); and `CHANNEL-PARTITION-BY`
(`src/stream-partition.lisp`) all drive the same loop: check `SCOPE`'s
cancellation, `RECV` the next value, stop once `INPUT` closes, otherwise run a
value-specific body. `src/stream.lisp`'s `%CONSUME-CHANNEL` names that loop
once; each caller supplies only the value variable, `INPUT`, `SCOPE`, the form
to return once `INPUT` closes -- which may itself have a side effect, as
`CHANNEL-BATCH` and `CHANNEL-PARTITION-BY` use it to flush a final partial
group -- and a body that may `(RETURN value)` to stop early, as
`CHANNEL-SOME`, `CHANNEL-EVERY`, `CHANNEL-FIND`, and `CHANNEL-TAKE-WHILE` do,
leaving later input values available to another receiver instead of draining
`INPUT` to exhaustion.

`CHANNEL-MERGE`, `CHANNEL-ZIP`, and `CHANNEL-CONCAT` (`src/stream-fan-in.lisp`)
share a second, smaller shape: validate a runtime list of input channels,
create one output channel of the requested buffer size, and return `(VALUES
output completion-promise)` for a stage that closes the output on every exit
path. `%WITH-CHANNEL-LIST-STAGE` is that setup/teardown written once; the
three stages differ only in how they read from the validated input list and
write to the output inside it.

Every stage above -- and every other one in `src/stream.lisp`,
`src/stream-fan-out.lisp`, and `src/stream-partition.lisp` -- ultimately
starts through `%START-CHANNEL-STAGE`, which takes its worker as an ordinary
function argument. Every one of those call sites, without exception, wrapped
that argument as `(LAMBDA () BODY)` and, for a stage that owns an output,
wrapped `BODY` again in `%WITH-CLOSED-STAGE-OUTPUTS`. That is `BODY`
unevaluated, needed for no reason a function argument could ever supply
(`%START-CHANNEL-STAGE`'s own argument is *called*, not macroexpanded, so
by the time it runs the caller's local variables it closes over are already
fully evaluated) -- exactly this document's own first criterion for a
macro. `%WITH-CHANNEL-STAGE` names that repeated wrapping once; every
stream stage that runs a literal body now reads `(%WITH-CHANNEL-STAGE (:SCOPE
... :OUTPUTS ...) BODY)` instead of the three-way nesting. The two exceptions
-- `CHANNEL-MAP-CONCURRENT` and `CHANNEL-MAP-UNORDERED`'s own worker pools,
just below -- still call `%START-CHANNEL-STAGE` directly, because they start
a *runtime-variable* number of copies of one named function
(`(LOOP REPEAT WORKER-LIMIT COLLECT (%START-CHANNEL-STAGE (FUNCTION WORKER)
...))`), which is exactly the shape a macro capturing one literal `BODY`
cannot express -- the same "runtime-variable shape" argument that keeps
`%RUN-DYNAMIC-SELECT` a function below.

`CHANNEL-MAP-CONCURRENT` and `CHANNEL-MAP-UNORDERED` live in their own file,
`src/stream-map-concurrent.lisp`, rather than alongside the fan-in stages
above: both read from exactly one `INPUT` channel and dispatch to a worker
pool over their own private `JOBS`/`RESULTS` channels, never touching
`%RUN-DYNAMIC-SELECT` or any other multi-input machinery, so grouping them
with genuinely many-input stages would have been by proximity, not by
shape. `%WORKER-LIMIT` is the one piece of arithmetic both need -- how many
of `PARALLELISM` workers to actually start, bounded by an optional
`EXECUTOR`'s own thread count and queue capacity -- named once rather than
duplicated between them.

## PROMISE-THEN and PROMISE-RACE: continuation-passing composition without blocking

`src/promise.lisp` is the core write-once cell (`MAKE-PROMISE`,
`DELIVER`/`DELIVER-ERROR`, `AWAIT`, and the thread-spawning `FUTURE`);
`src/promise-combinators.lisp` is everything that derives a new promise from
existing ones (`PROMISE-ALL-SETTLED`, `PROMISE-RACE`, `PROMISE-THEN`) --
the same split `src/scope-state.lisp`/`src/scope.lisp` already makes between
a layer's own state and what is built on top of it.

`PROMISE-THEN` is built directly on the same
continuation-registration primitive `PROMISE-ALL-SETTLED` already used
internally (`%OBSERVE-PROMISE`): register a callback to run once a promise
settles, called synchronously by whichever thread does the settling -- or
immediately, inline, if the promise is already settled. `PROMISE-THEN` wraps
that in the familiar `.then()` shape (fulfilled/rejected continuations,
returning a new promise for whichever one ran) without introducing a thread,
a queue, or any blocking wait: the composition is the continuation passing
itself.

`PROMISE-RACE` is the same composition aimed at a different shape:
`%OBSERVE-PROMISE` on every input, a lock-guarded flag so only the first
callback to run actually settles the result, every later one silently
discarded instead of raising `PROMISE-ALREADY-FULFILLED`. Still no thread, no
queue, no polling -- whichever input's own settling thread gets there first
does the result's settling too.

That lock-guarded "claim this race, once" flag is not unique to
`PROMISE-RACE`: `PROMISE-ALL`, `PROMISE-ANY`, and `PROMISE-TIMEOUT` each
need the identical guard, at seven call sites between them. `%UNLESS-DECIDED`
(run a body under the lock only if the flag is not already set) and
`%DECIDE-ONCE` (the common case of that body being nothing but setting the
flag) name the pattern once; `%WITH-RACE-CLEANUP` goes one step further for
`PROMISE-ALL` and `PROMISE-ANY` specifically, which additionally need to stop
observing every losing input once a winner is decided -- an anaphoric macro,
reaching `LOCK`, `DECIDED`, `COUNT`, `PROMISES`, and `OBSERVERS` by name from
the caller's own lexical scope, in the same spirit as `%DEFINE-KIT-CONDITION`
(`src/conditions.lisp`) capturing `CONDITION` for a `:REPORT` clause.

This continuation-passing composition is deliberately not how
`src/channel.lisp`'s `SEND`/`RECV` work, and that split is intentional rather
than incomplete. A promise is settled once, from whatever thread happens to
settle it, so registering a callback and returning immediately is the whole
contract. A channel is a CSP-style rendezvous: `RECV` must actually block
until a value -- or a close -- is there, because blocking *is* the
backpressure the abstraction promises (an unbuffered `SEND` returning is
supposed to mean "a receiver actually took this," not "a callback was
queued"). Turning `RECV`/`SEND` into callbacks would trade that guarantee for
a different, weaker one under the same names. `SELECT` (`src/select.lisp`)
and the reactive stream layer (`src/stream.lisp` and friends) build the
callback-shaped conveniences on top of that blocking core instead -- a
stage's worker thread still blocks on `RECV`, but the stage itself hands the
caller a channel and a promise, the same non-blocking handle `PROMISE-THEN`
would.

## Where continuation-passing is used, and where it deliberately is not

Collecting the continuation-passing shapes above in one place: `%OBSERVE-PROMISE`
(`src/promise.lisp`) is the primitive one, a callback registered against a
promise and invoked with its outcome by whichever thread settles it, never
polled for. `PROMISE-THEN`/`PROMISE-CATCH`/`PROMISE-FINALLY` and every
combinator in `src/promise-combinators.lisp` (`PROMISE-ALL`, `PROMISE-ANY`,
`PROMISE-RACE`, `PROMISE-ALL-SETTLED`, `PROMISE-TIMEOUT`) are built on it
directly, never on a thread, a queue, or a poll loop of their own. `SUBMIT`'s
`:ON-SETTLE` (`src/executor.lisp`) is the same primitive reused for the
executor's own bookkeeping (freeing a worker slot) rather than a public
result. `%SCOPE-ADD-WAKER`/`%SCOPE-SET-CHILD-CANCEL`
(`src/scope-state.lisp`) generalize it once more: a callback invoked on
cancellation instead of settlement, so `AWAIT-LATCH`, `AWAIT-BARRIER`, and
every stream stage's output-channel-closing waker (`src/stream.lisp`'s
`%START-CHANNEL-STAGE`) all plug into the same one cancellation-dispatch
point rather than each polling `CHECK-CANCELLED` on their own schedule.

Where it is *not* used is exactly as deliberate: `src/channel.lisp`'s
`SEND`/`RECV`, `src/select.lisp`'s `SELECT`, `src/latch.lisp`'s
`AWAIT-LATCH`/`AWAIT-BARRIER`, and `src/primitives.lisp`'s `%WAIT-UNTIL` all
block the calling thread rather than take a continuation, because each is
modeling a real rendezvous or a real deadline a caller is waiting to observe
directly -- turning any of them into a callback would change what a caller
watching for completion is actually synchronizing with. See "The unbuffered
channel is a real rendezvous" and "This continuation-passing composition is
deliberately not how `src/channel.lisp`'s `SEND`/`RECV` work" above for the
two places this project has already had to defend that line explicitly.

## %RUN-DYNAMIC-SELECT's clauses are continuations as data

`%RUN-DYNAMIC-SELECT` (`src/stream-fan-in.lisp`, see "Variable-arity SELECT
for stream fan-in" below) takes a list of `(CHANNEL . CONTINUATION)` pairs and
runs whichever `CONTINUATION` corresponds to the channel that became ready --
`CONTINUATION` itself a two-argument function of `(VALUE RECEIVED-P)`, called
instead of returning a value the way `RECV` would. That is
continuation-passing in the most literal sense available in Lisp: a
first-class function, built to be called instead of returned to, passed
alongside the channel it reacts to rather than woven into `SELECT`'s
macro-fixed clause bodies the way a static call site would write it.

`CHANNEL-MERGE-MAP` and `CHANNEL-SWITCH-MAP` build exactly such a list every
time around their own loop. Each names its continuations as `FLET` functions
-- `ON-INPUT` (react to `INPUT` producing a value or closing) and, for
`CHANNEL-SWITCH-MAP`, `ON-INNER` (react to the currently-forwarded inner
channel) -- so the loop body itself reads as data: `(CONS INPUT (FUNCTION
ON-INPUT))`, a channel paired with the continuation that runs when it is
ready, assembled fresh each iteration because which channels are even in play
(how many inner channels are open, whether `INPUT` itself has closed) changes
from one iteration to the next. Separating "which channels are being watched
this iteration" (the list `%RUN-DYNAMIC-SELECT` receives) from "what happens
when one of them is ready" (the two named `FLET` functions) is the same
data/logic split `benchmarks/run-benchmarks.lisp`'s `*BENCHMARKS*` table and
`src/conditions.lisp`'s `%DEFINE-KIT-CONDITION` table already make elsewhere
in this codebase.

## Which shapes become a DEFMACRO, and which stay a DEFUN

`src/` currently defines 21 macros against 145 functions: `%WITH-CHANNEL-LOCK`,
`%CHANNEL-NOTIFY`, `%DEFINE-KIT-CONDITION`, `%WITH-WORK-QUEUE-LOCK`,
`WITH-EXECUTOR`, `WITH-LOCK-HELD`, `%WAIT-UNTIL`, `%WITH-DEADLINE-WAIT`,
`%WITH-SCOPE-LOCK`, `%UNLESS-DECIDED`, `%DECIDE-ONCE`, `%WITH-RACE-CLEANUP`,
`WITH-TASK-SCOPE`, `%WITH-CHANNEL-LIST-STAGE`, `%WITH-CLOSED-STAGE-OUTPUTS`,
`%WITH-CHANNEL-STAGE`, `CHANNEL-PRODUCER`, `%CONSUME-CHANNEL`, `FUTURE`,
`SELECT`, and `WITH-TIMEOUT`. That ratio is not an oversight to correct
toward more macros; it reflects a specific, checkable criterion for which
shape a given piece of code needs -- checked again, and found to justify one
more macro, when `%START-CHANNEL-STAGE`'s call sites turned out to repeat the
same unevaluated-body wrapping at every one of them (see "%START-CHANNEL-STAGE
... `%WITH-CHANNEL-STAGE`" above).

A macro earns its place here for one of two reasons. Either it needs
`BODY` unevaluated -- an unwind-protected critical section
(`%WITH-CHANNEL-LOCK`, `%WITH-SCOPE-LOCK`, `%WITH-DEADLINE-WAIT`), a
resource-scoped binding (`WITH-EXECUTOR`, `WITH-TASK-SCOPE`,
`WITH-TIMEOUT`, `CHANNEL-PRODUCER`, `%WITH-CHANNEL-STAGE`), or a loop skeleton
whose per-iteration work varies by caller (`%CONSUME-CHANNEL`,
`%WITH-RACE-CLEANUP`) -- none of which a function can express, since a
function's arguments are evaluated before it ever runs. Or its clause/branch
shape is known at compile time and inlining it avoids a real runtime cost:
`SELECT` expands every clause's `TRY-SEND`/`TRY-RECV` probe directly into its
expansion specifically so choosing a ready clause is a direct call, not a
dispatch through a stored handler vector (see "SELECT sleeps; it does not
poll" above).

Neither reason applies to most of the other 145. `src/stream-fan-in.lisp`'s
`%RUN-DYNAMIC-SELECT` is the clearest negative case: it exists *because*
`SELECT`'s macro-fixed clause count cannot express a multiplexer over a
channel list whose length is only known at runtime, so making it a macro
would delete the one capability it was written to have. The same argument
covers ordinary data-shaped operations throughout `src/channel.lisp`,
`src/promise.lisp`, `src/executor.lisp`, and the stream stage functions:
`CHANNEL-MERGE`'s channel list, `CHANNEL-BATCH`'s `SIZE`, and
`EXECUTOR-MAP`'s `MAX-IN-FLIGHT` are all runtime values a macro's
compile-time expansion has no access to. Converting these to macros would
not add a capability; it would only remove the one a function already
provides -- ordinary argument evaluation -- for no benefit, which is
exactly the "macro-first" antipattern On Lisp itself warns against under a
different name.

## Where data is kept separate from the logic that processes it

Three concrete places this separation is already load-bearing, not just
aspirational: `src/package.lisp`'s `:EXPORT` list is a flat list of keyword
symbols -- pure data, with zero logic mixed into it, and it is the entire
definition of this library's public API surface (see "Stability" in
[Compatibility](compatibility.md)). `src/conditions.lisp`'s thirteen
conditions are each a `%DEFINE-KIT-CONDITION` call supplying only what
varies -- a name, a list of `(SLOT-NAME DOCUMENTATION)` data tuples, a
`:REPORT` format string, and its format arguments -- with the reader-naming
convention, the `:INITARG` derivation, and the `CL-CONCURRENT-KIT-ERROR`
subclassing written once in the macro rather than repeated per condition
(see that file's own header comment). `benchmarks/run-benchmarks.lisp`'s
`%REPORT-BENCHMARK` separates the one piece of logic every benchmark
shares (running `cl-weave:benchmark` and formatting `median-ms`/`mean-ms`/
`minimum-ms`/`maximum-ms`) from the data that varies per call -- a name
string and a body form -- rather than repeating the `FORMAT` call at each
of the file's nine benchmarks.

Where this split does *not* appear -- `%SELECT-PARSE-CLAUSES`'s clause
dispatch, `%CHANNEL-ADD-WAITER`'s interest-bit bookkeeping -- the "data"
side of a hypothetical split would be nothing but small closures over
lexical state (a value transform, a comparison, a callback), which a data
table would need to hold as data anyway; splitting further would move the
same logic sideways into the table's payload rather than actually
separating it from anything.

## Why SPEED 0, and why in the .asd rather than a DECLAIM

This system compiles its own files at `(optimize (speed 0) ...)`. The policy
dates from a bisection against SBCL 2.6.0: at the default `SPEED 1`, compiling
this system in one image -- specifically the
`SPAWN`/`SPAWN-CHILD`/`%SPAWN-EXECUTOR-CHILD` dispatch in `src/scope.lisp`,
once `src/select.lisp`, `src/executor.lisp`, and `src/scope-state.lisp` have
all already contributed type information to the same compilation -- was
observed not to return in any practical time. Every operation in this library
is dominated by a mutex acquisition or an OS-level wait, so `SPEED` was never
the bottleneck a caller could measure, and the policy is kept on that basis:
it costs nothing real even where the compiler would have terminated anyway.

Where it is applied changed on 2026-08-01. It used to be a global
`(declaim (optimize ...))` in `src/package.lisp`, which was wrong in both
directions at once.

Too narrow, first: SBCL binds its compilation policy around both
`COMPILE-FILE` and `LOAD`, so an `OPTIMIZE` proclamation made *by* a file is
scoped to that file. Compile an `a.lisp` carrying the declaim, `LOAD`
`a.fasl`, then compile a `b.lisp`, and `b.lisp` still compiles at `SPEED 1`.
The declaim therefore covered `src/package.lisp` and nothing else -- leaving
`src/scope.lisp`, the very file it was written for, uncovered.

Too broad, second, in the case where it had worked: a `DECLAIM` proclaims
globally and would have stayed in force for everything compiled afterwards in
the same image. Since ASDF builds dependencies before dependents, "afterwards"
means every consumer's entire source tree.

`cl-concurrent-kit.asd` now uses ASDF's `:around-compile` instead. It is a
per-file compile hook, so it covers every file in `:components` regardless of
build order and regardless of whether some earlier fasl was cached rather than
recompiled, and it wraps each compile in `WITH-COMPILATION-UNIT`'s `:POLICY`,
which is dynamically scoped and restores the caller's own policy exactly on
the way out. The system gets the policy; nobody else does.

## When "as much as possible" is satisfied

Three of this project's stated goals -- push as much as possible into
`DEFMACRO`, use continuation-passing style as much as possible, improve
complex functions' readability -- are phrased as a direction rather than a
finish line. Applied without a stopping rule, each would justify rewriting
the entire codebase indefinitely: some function is always the next-most
complex one, some `DEFUN` could always theoretically become a `DEFMACRO`,
some blocking call could always theoretically be reached through a callback.
This project's actual stopping rule, applied consistently everywhere above:

- **DEFMACRO vs. DEFUN** ("Which shapes become a DEFMACRO, and which stay a
  DEFUN" above): a shape earns a macro only for one of two checkable reasons
  -- needing `BODY` unevaluated, or a compile-time-fixed shape a real
  function call could not express (`SELECT`'s clause count). Every one of
  this codebase's 145 functions was written as a function because neither
  reason applies to it; converting one to a macro without one of those two
  reasons would not raise the abstraction level, it would only make the
  function harder to trace with `DESCRIBE-FUNCTION` and impossible to pass
  as a first-class value -- a real regression, not a neutral stylistic
  choice.
- **Continuation-passing vs. blocking** ("Where continuation-passing is
  used, and where it deliberately is not" and "%RUN-DYNAMIC-SELECT's clauses
  are continuations as data" above): CPS is used everywhere a caller is
  merely told the outcome of something that already happened elsewhere
  (`%OBSERVE-PROMISE`, `%RUN-DYNAMIC-SELECT`'s clause continuations,
  `%SCOPE-ADD-WAKER`), and never where a caller is a genuine party to a
  rendezvous or a real deadline it is waiting to observe directly
  (`CHANNEL`/`SELECT`, `AWAIT-LATCH`/`AWAIT-BARRIER`, `%WAIT-UNTIL`).
  Converting the second group to callbacks would not be "more CPS," it would
  silently change what those primitives guarantee a caller is synchronized
  with -- the same failure mode `PROMISE-RACE`'s own docstring already warns
  against for a channel's `SEND`/`RECV`.
- **Readability extraction** ("The high-complexity readability pass" above):
  every function on the original byte-span ranking was read individually,
  not filtered by a size threshold alone. Eight were genuinely restructured;
  `%CALL-WITH-TIMEOUT` was left alone because its `HANDLER-BIND` clause's
  `RETURN-FROM` must stay lexically inside the `BLOCK` it targets, so
  extracting it would either break that or add a wrapper that renames the
  code without clarifying it. Two more functions
  (`CHANNEL-MERGE-MAP`/`CHANNEL-SWITCH-MAP`) were found and fixed afterward
  by asking a different question -- not "is this long" but "does this
  function build an unnamed continuation inline" -- and applied the same
  treatment. `%CHANNEL-MERGE-CLAUSES`, `CHANNEL-PARTITION-BY`,
  `CHANNEL-BROADCAST`, and `EXECUTOR-MAP` were read against that same
  question afterward and left alone: each is already either a single
  small conditional or already has its own named local helper from earlier
  work, and a further split would move lines without removing any real
  tangle. `paredit inspect duplicates` was also run across `t/` looking for
  copy-pasted test logic that should become a shared helper; its only large
  groups are incidental similarity between distinct test scenarios' own
  setup calls (`(send channel :some-keyword)`, one per scenario) rather than
  duplicated logic, so no further test abstraction followed from it.

The criterion in each case is the same shape: change the code where a
concrete, checkable reason exists, and leave it where none does, rather than
treating a superlative goal as license to keep changing code that no longer
has a defect to fix.
