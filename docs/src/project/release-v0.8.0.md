# v0.8.0 release notes

## Interruptible scopes

`WITH-INTERRUPTIBLE-SCOPE` runs a body on the calling thread and exposes a
scope object to share with a requester. `REQUEST-INTERRUPTION` requests an
exit from that specific body. The boundary signals `OPERATION-INTERRUPTED`,
whose readers expose the scope and reason.

Body condition handlers, including `IGNORE-ERRORS`, do not observe the
boundary's `OPERATION-INTERRUPTED` condition. User cleanup can replace the
pending transfer with its own non-local exit.
Ordinary requests deduplicate after the first acceptance and let user cleanup
unwind. `:force t` queues another interruption while the boundary remains live,
even during prior interruption cleanup; delivery can cut short the remaining
cleanup. The latest accepted force request replaces the reported reason.
Requests to a `NIL` or closed scope return `NIL`. Closing the scope prevents
delayed callbacks from affecting later code.

Force cannot stop cleanup that repeatedly replaces every
transfer with its own non-local exit or error. If cleanup replaces a delivered transfer and the body resumes
and returns normally, the boundary still signals `OPERATION-INTERRUPTED` and
discards the returned values.

A request from a signal handler on the target thread must be its last action
before returning. Interrupt-enabling work can deliver a queued request while
the handler is still on the stack; queueing alone does not guarantee that
the handler returns first.

A request returning `T` was accepted, but normal completion can still win
before any request is delivered. A request delivered during cleanup for a body's `THROW` or
error can replace that pending exit.

SBCL defers interruption while interrupts are disabled and during garbage
collection. An enclosing `WITHOUT-INTERRUPTS` can also postpone draining
scope callbacks past scope return; those callbacks then do nothing.
Force requests respect the same delivery delays.
Callers must protect resource acquisition and cleanup-state updates against
asynchronous exits. See the
[API reference](https://github.com/nerima-lisp/cl-concurrent-kit/blob/v0.8.0/docs/src/reference/api.md#interruptible-scopes).

## Timeout race fix

`WITH-TIMEOUT` uses the same interruption boundary. A timer expiring during
the scope's teardown cannot turn an already completed body into a timeout
if no timeout was previously delivered. If cleanup replaced an earlier
delivered transfer and the body resumed and returned normally, the boundary
still signals `OPERATION-TIMED-OUT` and discards those return values.
The macro retains its duration argument and condition type.

The following behavior changes affect callers of earlier versions:

- A body handler for `SERIOUS-CONDITION` no longer catches the timeout;
  `OPERATION-TIMED-OUT` is signaled at the boundary after unwinding.
- `WITH-TIMEOUT` no longer provides a `CONTINUE` restart for expiry.
- `WITH-TIMEOUT` captures the zero-argument `*CLOCK*` function at entry and
  checks its deadline in internal-time units when the SBCL timer runs.
  In v0.7.0, rebinding `*CLOCK*` inside the body could change deadline
  checks; v0.8.0 keeps using the entry clock despite such a rebind. An
  early callback rearms the timer for the remaining interval. Advancing an
  injected clock does not wake the real timer. Closed callbacks do nothing
  and cannot rearm it.
- If an enclosing `WITHOUT-INTERRUPTS` prohibits interrupts for the entire
  scope, the body can complete without the timeout ever firing. The macro
  preserves the caller's policy; callbacks delivered after closure do nothing.

## Compatibility with v0.7.0

The v0.7.0 clock-function contract and pre-arrival barrier cancellation behavior
are retained. `*CLOCK*` remains a zero-argument function returning internal-time
units, defaulting to `GET-INTERNAL-REAL-TIME`. The new interruption API and
timeout boundary behavior described above are the v0.8.0 additions.
