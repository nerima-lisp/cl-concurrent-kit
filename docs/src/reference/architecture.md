# Architecture

## Why SBCL only, wrapping sb-thread directly

[nerima-lisp's coding standard](https://github.com/nerima-lisp/.github/blob/main/CODING_STANDARD.md)
targets SBCL exclusively and treats `sb-thread` as the default choice over
adding bordeaux-threads as an external dependency: every other repository in
the org that needs threads already calls `sb-thread` directly. This project
follows that precedent instead of reintroducing the portability layer it
would otherwise have depended on -- see `src/primitives.lisp` for the thin
wrapper this produces.

## Dependencies: SBCL/sb-thread, plus CL-BOUNDARY-KIT and CL-DATE-KIT for deadlines

The same [coding standard](https://github.com/nerima-lisp/.github/blob/main/CODING_STANDARD.md)
that settles SBCL-vs-portability-layer above settles the *threading* layer
too: prefer what SBCL already ships over adding a dependency for it,
org-wide. `src/primitives.lisp` is still a thin wrapper directly over
`sb-thread`, nothing more. Deadline arithmetic is a deliberate exception,
adopted once a real gap was found rather than assumed: every public
`:TIMEOUT` argument in this library (`AWAIT`, `RECV`, `SEND`, `SELECT`'s
`:TIMEOUT` clause, `AWAIT-LATCH`, `AWAIT-BARRIER`,
`AWAIT-EXECUTOR-TERMINATION`, `SHUTDOWN-EXECUTOR`, `WITH-EXECUTOR`,
`WITH-TASK-SCOPE`, `PROMISE-TIMEOUT`, `WITH-TIMEOUT`) accepts a
`CL-DATE-KIT:DURATION` -- never a raw seconds number -- and the clock behind
`src/primitives.lisp`'s `%DEADLINE-FROM-TIMEOUT`/`%SECONDS-UNTIL-DEADLINE`
is `CL-BOUNDARY-KIT:CLOCK-MONOTONIC` on the `*CLOCK*` special variable, not
a direct `GET-INTERNAL-REAL-TIME` call. Both are consumed exactly as the
project's own convention asks -- no wrapper type, no re-exported
constructor, no adapter layer around either library's own API -- a caller
builds a `CL-DATE-KIT:DURATION` with `CL-DATE-KIT:DURATION-OF-SECONDS` (or
`-MILLIS`/`-MICROS`/`-NANOS`) directly, and a test rebinds `*CLOCK*` to
`(CL-BOUNDARY-KIT:MAKE-FAKE-CLOCK)` directly, with nothing of this
project's own in between. `cl-concurrent-kit.asd`'s `:depends-on` on the
main system names both by name; `cl-concurrent-kit/test` depends on them
only transitively, through `cl-concurrent-kit` itself. This is a deliberate
break from every earlier release's "dependency-free" description, not an
accidental one -- see the "No backward-compatibility surface" section
below for why a clean break, not a dual raw-number/Duration API, was the
only option once the project's own no-compat-shim rule applied here too.

`cl-weave` (the test suite, `cl-concurrent-kit/test`'s own `:depends-on`),
`cl-cli` (`benchmarks/run-benchmarks.lisp`'s argument parsing, reached only
through `flake.nix`'s `CL_SOURCE_REGISTRY` for that one script), and
`cl-nix-forge` (`flake.nix`'s own packaging) remain outside the *main*
system's dependency list -- none reachable from a consumer that only loads
the library for its concurrency primitives, same reasoning as before.

The rest of the org's catalog (checked against
[github.com/orgs/nerima-lisp/repositories](https://github.com/orgs/nerima-lisp/repositories)
via `gh api orgs/nerima-lisp/repos`, re-surveyed as of the CL-DATE-KIT/
CL-BOUNDARY-KIT adoption) still fares no better against the "real call
site, not a dependency in search of a use" test: `cl-json-kit`,
`cl-regex-kit`, `cl-codec-kit`, `cl-parser-kit`, and `cl-tty-kit` all answer
a data-format, text, or host-environment need this package -- concurrency
primitives plus deadline arithmetic -- has no call site for at all.
`cl-dataflow-kit` is the closest remaining *spirit* match (composable
computation graphs) but overlaps this project's own domain closely enough
that depending on it would mean wrapping its abstractions around this
package's -- the adapter this architecture still avoids -- rather than
consuming a narrow, orthogonal concern the way `CLOCK`/`DURATION` are
consumed above. `cl-cc`, `nshell`, `loom`, `cl-tmux`, and the `cl-cc-*`
compiler-internals repositories are a different domain (a self-hosting
compiler, a shell, a terminal multiplexer, a terminal editor) with no
natural connection to this one at all. `cl-process-kit` (external process
execution) and `cl-history-kit` (REPL/shell history) are interactive-tooling
concerns this in-process concurrency library has no call site for, same as
the data-format group above. `cl-prolog-kit` -- a logic-programming engine that,
notably, is itself built with "CPS proof search" per its own
description -- answers a different question (searching for a proof) than
anything here needs solved. `cl-log-kit` is the one candidate with a real,
if single, call site (`src/executor.lisp`'s worker-loop `(FORMAT
*ERROR-OUTPUT* ...)`), discussed on its own terms above -- still not
adopted, for the same circular-dependency reason as ever (`cl-log-kit`
itself depends on `cl-concurrent-kit`).

`cl-host-kit` is used only test/benchmark-adjacent, transitively through
`cl-cli`, never as a `cl-concurrent-kit` main-system dependency.

## No backward-compatibility surface to eliminate

A codebase carries backward-compatibility weight when a later API replaces
an earlier one and both must keep working -- a deprecated alias, a
compatibility shim, a `#+old-sbcl` branch preserved past its last caller.
Every release so far (v0.1.0 through v0.6.0) has changed public symbols'
shapes outright rather than deprecating them -- `%CHANNEL-DEQUEUE` and the
ring-buffer `CHANNEL`/`%WORK-QUEUE` internals replaced the FIFO-backed ones
wholesale in v0.3.0, for instance, with no transitional alias kept alongside
either. Grepping the tree confirms the result: zero matches across `src/`,
`t/`, and the `.asd` for `deprecated`, `legacy`, `obsolete`, `backward-compat`,
or `shim`, in any casing -- re-verified as part of the v0.4.0 refactor and
again after the 2026 file-splitting/macro-consolidation pass (which moved
code across eight files without leaving an old name behind at either end),
not just inherited from an earlier audit. The absence is the intended
state, not a gap -- keep it that way by deleting rather than deprecating
when a public symbol's shape changes, exactly as `cl-concurrent-kit.asd`'s
pre-`1.x` version (no compatibility promise yet) allows.

The CL-DATE-KIT/CL-BOUNDARY-KIT adoption above is this rule applied to its
largest surface yet: every public `:TIMEOUT` argument changed from a raw
seconds number to a `CL-DATE-KIT:DURATION` in one pass, with no transitional
period accepting both shapes. A dual raw-number/Duration `:TIMEOUT` was
considered and rejected -- it would have meant a runtime `TYPECASE` (or
`REAL`-vs-`DURATION` dispatch) at every one of the ten affected call sites,
forever, the textbook shape of the compatibility shim this section exists to
keep out. Every caller in this repository's own `t/*.lisp` and every example
in `docs/src` was converted in the same commit as the API change itself.

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
`WITH-TASK-SCOPE` accepts an optional `:TIMEOUT` (a `CL-DATE-KIT:DURATION`)
bounding only the wait for already-running children once the body itself has finished; on
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
- `PROMISE-ALL` and `PROMISE-ANY` (`src/promise-racing.lisp`) each
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

## Four files split along their own internal seam

`channel.lisp`, `stream.lisp`, `promise-combinators.lisp`, and
`executor.lisp` each grew past a size where one file was doing two
genuinely separable jobs. Each was split by finding the actual seam --
never a mechanical "cut at N lines" -- and the load-order direction across
the split was decided by grepping the whole tree for every moved symbol
first, not assumed:

- `channel.lisp` keeps the `CHANNEL` struct and its
  `SEND`/`RECV`/`TRY-SEND`/`TRY-RECV`/`CLOSE-CHANNEL` core, plus the
  `+CHANNEL-NOTIFY-*+` constants and `%CHANNEL-NOTIFY` macro those functions
  expand at compile time. `channel-waiters.lisp` holds the multi-channel
  waiter-registration machinery (`%CHANNEL-WAITER-BUCKET`,
  `%CHANNEL-NOTIFY-WAITERS`, `%CHANNEL-ADD-WAITER`, `%CHANNEL-REMOVE-WAITER`)
  that `SELECT` and `%RUN-DYNAMIC-SELECT` consume externally, and loads
  *after* `channel.lisp` -- the reverse of the split's own file-list order --
  because those functions need the `CHANNEL` struct and `%WITH-CHANNEL-LOCK`
  macro already defined at their own compile time.
- `stream.lisp` keeps the producing stages (`%START-CHANNEL-STAGE` through
  `CHANNEL-SCAN`) and `%CONSUME-CHANNEL` itself; `stream-terminal.lisp` holds
  only the six functions that call it to consume a channel down to one
  promise result (`CHANNEL-REDUCE`, `CHANNEL-COLLECT`, `CHANNEL-EACH`,
  `CHANNEL-SOME`, `CHANNEL-EVERY`, `CHANNEL-FIND`). `%CONSUME-CHANNEL` itself
  stayed in `stream.lisp` rather than moving with its most obvious callers:
  `stream-fan-out.lisp` and `stream-partition.lisp` also expand it, at five
  more call sites the initial split missed by only checking the two files
  being split -- discovered when moving it produced a hard compile error
  (`return for unknown block: NIL`, from a bare `(RETURN)` that was supposed
  to be inside the macro's own `(LOOP ...)` expansion) in a *third* file that
  compiles before `stream-terminal.lisp` ever would.
- `promise-combinators.lisp` keeps the chaining/settlement family;
  `promise-racing.lisp` holds the racing family, as described above.
- `executor.lisp` keeps the `EXECUTOR`/`%EXECUTOR-TASK` machinery;
  `executor-work-queue.lisp` holds the internal `%WORK-QUEUE` ring-buffer
  subsystem (struct, `%WITH-WORK-QUEUE-LOCK`, `%WORK-QUEUE-GROW`/`PUSH`/`POP`)
  and loads *before* `executor.lisp`, since `EXECUTOR-SHUTDOWN-P` and
  friends expand `%WITH-WORK-QUEUE-LOCK` at their own compile time.
  `%WORK-QUEUE-CLOSE` stayed in `executor.lisp` despite its name -- it takes
  an `EXECUTOR`, not a `%WORK-QUEUE`, and settles cancelled tasks via
  `%EXECUTOR-TASK-CANCEL`, so it belongs to the layer that owns those.

The `channel.lisp`/`stream.lisp` pair is the cautionary tale worth keeping:
a symbol's "natural" home by proximity to its most obvious use is not the
same question as which file's compile-time dependencies actually require
it, and only a whole-tree grep answers the second question reliably. An
undefined *macro* at a caller's compile time fails loudly, in a way that
points at the wrong cause (a stray `RETURN`, not a missing definition); an
undefined *function* reference in the same position -- confirmed while
diagnosing `channel-waiters.lisp`'s own, correctly-decided load order --
only produces a `STYLE-WARNING` and an otherwise-successful, silently
incorrect build. Neither hazard shows up from testing the split files in
isolation; only compiling the whole system, in `:SERIAL T` order, catches it.

## EXECUTOR-MAP's own settlement bug, caught before it shipped

`EXECUTOR-MAP` (`src/executor.lisp`) used to end with
`(MAP 'LIST (FUNCTION AWAIT) PROMISES)` -- a manual, in-order wait over
each submitted call's own promise. A continuation-passing rewrite to
`(AWAIT (PROMISE-ALL PROMISES))` looked like a direct CPS-composition win
(`PROMISE-ALL` already exists, already composes N promises into one), and
would have passed the existing test suite, which asserts only `(SIGNALS
SIMPLE-ERROR ...)` on a single-failure case -- not which failure, nor
whether every submitted call had actually settled first.

It is not equivalent. `PROMISE-ALL` decides and delivers as soon as the
*first-in-time* failure is observed, stopping observation of every other
still-pending input; the original `MAP`/`AWAIT` loop blocks through each
promise in *list order*, so it always reports the lowest-index failure once
every call up to and including it has settled -- exactly what
`EXECUTOR-MAP`'s own docstring promises ("propagates once every
already-submitted call has itself settled") and what a test added
alongside this fix (`t/executor-test.lisp`, two elements where the
higher-index one fails first in time) is built to tell apart. The
CPS-correct fix instead composes through `PROMISE-ALL-SETTLED`
(`src/promise-combinators.lisp`) -- which waits for every input regardless
of outcome -- and picks the first `:FAILED` settlement out of its
in-order result list by hand:

```lisp
(let ((settlements (await (promise-all-settled promises))))
  (dolist (settlement settlements)
    (when (eq :failed (promise-settlement-state settlement))
      (error (promise-settlement-condition settlement))))
  (mapcar (function promise-settlement-value) settlements))
```

Still one CPS-composed wait, no manual per-item loop -- but the *right*
combinator for a contract that requires every input to settle, not the one
that merely composes promises in general. The lesson generalizes: two
`PROMISE-COMBINATORS` functions can both be "the CPS way to wait on many
promises" and still guarantee different things about ordering and
completeness; picking one over the other is a semantic decision the
docstring and the test suite must already answer, not a mechanical
find-the-nearest-combinator substitution.

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
same shape: convert the caller's `:TIMEOUT` (a `CL-DATE-KIT:DURATION`) to a
seconds rational once, at that one public entry point, compute a deadline
once from it, block on `%WAIT-UNTIL` until a predicate is satisfied or the
deadline passes, and signal `OPERATION-TIMED-OUT` on the latter (its own
`:TIMEOUT` slot carries that same seconds rational, not the original
`DURATION` object -- see `src/conditions.lisp`). `src/primitives.lisp`'s
`%WITH-DEADLINE-WAIT` macro is that shape written once; every caller supplies
only what actually varies -- the condition variable, the lock, the predicate,
and the operation keyword the resulting condition names. `src/channel.lisp`'s
unbuffered `SEND` calls it twice against one shared deadline (see its own
comment for why the deadline, not the timeout, is what must not be
recomputed between the two waits). The deadline itself is computed against
`*CLOCK*` (a `CL-BOUNDARY-KIT:CLOCK`, `src/primitives.lisp`) rather than a
direct `GET-INTERNAL-REAL-TIME` call -- real by default, rebindable to a
`CL-BOUNDARY-KIT:FAKE-CLOCK` so a test can make the deadline *arithmetic*
deterministic. This does not extend to the actual blocking waits
themselves: `CONDITION-WAIT`, `WAIT-ON-SEMAPHORE`, and `SB-EXT:WITH-TIMEOUT`
are real SBCL primitives with no fake-clock hook, so a test asserting an
actual timeout still sleeps in real time, same as before.

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
`CHANNEL-EVERY`, and `CHANNEL-FIND` (`src/stream-terminal.lisp`); `CHANNEL-BROADCAST`,
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
`src/promise-combinators.lisp` and `src/promise-racing.lisp` together are
everything that derives a new promise from existing ones -- the same split
`src/scope-state.lisp`/`src/scope.lisp` already makes between a layer's own
state and what is built on top of it. `src/promise-combinators.lisp` keeps
the chaining/settlement family (`PROMISE-THEN`, `PROMISE-CATCH`,
`PROMISE-FINALLY`, `PROMISE-ALL-SETTLED`), which mirror or observe every
input through to completion and never stop watching one early;
`src/promise-racing.lisp` holds the family that races inputs against each
other and stops observing the rest once the outcome is decided
(`PROMISE-RACE`, `PROMISE-ALL`, `PROMISE-ANY`, `PROMISE-TIMEOUT`) and the
`%UNLESS-DECIDED`/`%DECIDE-ONCE`/`%WITH-RACE-CLEANUP` machinery that shape
needs, which promise-combinators.lisp's own family does not.

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
polled for. `PROMISE-THEN`/`PROMISE-CATCH`/`PROMISE-FINALLY`/`PROMISE-ALL-SETTLED`
(`src/promise-combinators.lisp`) and `PROMISE-ALL`/`PROMISE-ANY`/`PROMISE-RACE`/
`PROMISE-TIMEOUT` (`src/promise-racing.lisp`) are all built on it
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

`src/` currently defines 22 macros against 137 functions (`paredit inspect
definitions`'s own by-category count -- the authoritative one; re-run it
rather than hand-recounting after a future change): `%WITH-CHANNEL-LOCK`,
`%CHANNEL-NOTIFY`, `%DEFINE-KIT-CONDITION`, `%WITH-WORK-QUEUE-LOCK`,
`WITH-EXECUTOR`, `WITH-LOCK-HELD`, `%WAIT-UNTIL`, `%WITH-DEADLINE-WAIT`,
`%WITH-SCOPE-LOCK`, `%UNLESS-DECIDED`, `%DECIDE-ONCE`, `%WITH-RACE-CLEANUP`,
`WITH-TASK-SCOPE`, `%WITH-CHANNEL-LIST-STAGE`, `%WITH-CLOSED-STAGE-OUTPUTS`,
`%WITH-CHANNEL-STAGE`, `CHANNEL-PRODUCER`, `%CONSUME-CHANNEL`, `FUTURE`,
`SELECT`, `WITH-TIMEOUT`, and `%BOOTSTRAP-CHANNEL-WORKERS`. That ratio is
not an oversight to correct toward more macros; it reflects a specific,
checkable criterion for which shape a given piece of code needs -- checked
again, and found to justify one more macro twice over: once when
`%START-CHANNEL-STAGE`'s call sites turned out to repeat the same
unevaluated-body wrapping at every one of them (see "%START-CHANNEL-STAGE
... `%WITH-CHANNEL-STAGE`" above), and again when `CHANNEL-MAP-CONCURRENT`
and `CHANNEL-MAP-UNORDERED` (`src/stream-map-concurrent.lisp`) turned out to
repeat an identical ~15-line worker-pool bootstrap block that needed a
`RETURN-FROM` naming its own caller -- exactly the "`BODY` unevaluated"
case a function cannot express, since only a macro's expansion can name the
right enclosing function at each of its two call sites.

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

Neither reason applies to most of the other 137. `src/stream-fan-in.lisp`'s
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
  this codebase's 137 functions was written as a function because neither
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
