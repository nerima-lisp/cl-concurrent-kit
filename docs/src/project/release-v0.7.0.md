# v0.7.0 release notes (draft)

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

A request from a signal handler on the target thread must be its last action
before returning. Interrupt-enabling work can deliver a queued request while
the handler is still on the stack; queueing alone does not guarantee that
the handler returns first.

A request returning `T` was accepted, but normal completion can still win
before delivery. A request delivered during cleanup for a body's `THROW` or
error can replace that pending exit.

SBCL defers interruption while interrupts are disabled and during garbage
collection. An enclosing `WITHOUT-INTERRUPTS` can also postpone draining
scope callbacks past scope return; those callbacks then do nothing.
Force requests respect the same delivery delays.
Callers must protect resource acquisition and cleanup-state updates against
asynchronous exits. See the
[API reference](../reference/api.md#interruptible-scopes).

## Timeout race fix

`WITH-TIMEOUT` uses the same interruption boundary. A timer expiring during
the scope's teardown cannot turn an already completed body into a timeout.
The body's handlers do not observe the boundary's `OPERATION-TIMED-OUT`
condition. The macro retains its duration argument and condition type.

The following behavior changes affect callers of earlier versions:

- A body handler for `SERIOUS-CONDITION` no longer catches the timeout;
  `OPERATION-TIMED-OUT` is signaled at the boundary after unwinding.
- `WITH-TIMEOUT` no longer provides a `CONTINUE` restart for expiry.
- `WITH-TIMEOUT` uses SBCL's timer and ignores `*CLOCK*`.

## Unreleased changes since v0.6.1

The release also includes these commits already on `main`:

| Commit | Change |
|---|---|
| `7971169` | Update documentation references to the renamed cl-prolog-kit and cl-dataflow-kit repositories. |
| `b0ed408` | Merge the repository-name documentation update from PR #4. |
| `f71a4aa` | Shorten implementation comments without changing executable forms. |
| `f0d2404` | Shorten coverage and benchmark tooling comments and realign coverage exclusion locations after the comment edits. The excluded source lines and coverage thresholds are unchanged. |
| `1e32037` | Refresh the architecture, compatibility, and introductory documentation and repair links to the architecture sections. |
