# v0.7.0 release notes (draft)

## Interruptible scopes

`WITH-INTERRUPTIBLE-SCOPE` runs a body on the calling thread and exposes a
scope object to share with a requester. `REQUEST-INTERRUPTION` requests an
exit from that specific body. The boundary signals `OPERATION-INTERRUPTED`,
whose readers expose the scope and reason.

Body condition handlers, including `IGNORE-ERRORS`, cannot suppress the exit.
`UNWIND-PROTECT` cleanup runs before the boundary signals the condition.
Requests received after body completion have no effect, and delayed scope
callbacks cannot affect later code. A request from a signal handler on
the target thread is delivered after the handler returns.

SBCL defers interruption while interrupts are disabled and during garbage
collection. An enclosing `WITHOUT-INTERRUPTS` can also postpone draining
scope callbacks past scope return; those callbacks then do nothing.
Callers must protect resource acquisition and cleanup-state updates against
asynchronous exits. See the
[API reference](../reference/api.md#interruptible-scopes).

## Timeout race fix

`WITH-TIMEOUT` uses the same interruption boundary. A timer expiring during
the scope's teardown cannot turn an already completed body into a timeout.
The body's handlers cannot suppress its deadline. The macro retains its
duration argument and `OPERATION-TIMED-OUT` condition.

## Changes carried forward from v0.6.1

The release also includes these commits already on `main`:

| Commit | Change |
|---|---|
| `7971169` | Update documentation references to the renamed cl-prolog-kit and cl-dataflow-kit repositories. |
| `b0ed408` | Merge the repository-name documentation update from PR #4. |
| `f71a4aa` | Shorten implementation comments without changing executable forms. |
| `f0d2404` | Shorten coverage and benchmark tooling comments and realign coverage exclusion locations after the comment edits. The excluded source lines and coverage thresholds are unchanged. |
| `1e32037` | Refresh the architecture, compatibility, and introductory documentation and repair links to the architecture sections. |
