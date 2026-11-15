# Compatibility

## Implementation and dependencies

The library targets SBCL. Its Nix CI uses SBCL 2.6.6. Since v0.7.0,
`*clock*` is a zero-argument function defaulting to `get-internal-real-time`;
its monotonicity depends on the SBCL build. When
`:os-provides-clock-gettime` is present in `sb-impl:+internal-features+`,
SBCL uses `CLOCK_MONOTONIC` on macOS and `CLOCK_MONOTONIC_COARSE` on Linux.
The runtime dependency is [cl-date-kit](https://github.com/nerima-lisp/cl-date-kit).
The test system
additionally uses [cl-weave](https://github.com/nerima-lisp/cl-weave).
Benchmark scripts use [cl-cli](https://github.com/nerima-lisp/cl-cli), which
uses [cl-host-kit](https://github.com/nerima-lisp/cl-host-kit) on SBCL.

The implementation uses SBCL's native thread and synchronization facilities
in `src/primitives.lisp`. Interruptible scopes and preemptive timeouts also
use SBCL's interrupt and timer facilities. Porting to another Common Lisp
implementation requires replacing these mechanisms.

## Platforms

CI gates `x86_64-linux`. The flake also declares `aarch64-darwin` for local
development and builds. The platform declarations are in `flake.nix`.

## Stability

The public API is the export list in `src/package.lisp`. Internal,
package-qualified symbols are not covered by semantic versioning.

Dependency versions are pinned in `flake.lock`; updates must pass the
repository's normal `nix flake check` gate.

## Production considerations

- Blocking operations with `:timeout` signal `operation-timed-out` on expiry.
- Library failures use conditions derived from
  `cl-concurrent-kit-error`.
- Public promises, channels, executors, task scopes, latches, and barriers
  are safe to share through their documented operations. Direct slot mutation
  is not part of the API.
- Executors own worker threads until `shutdown-executor` is called.
- Cancellation through `check-cancelled` and `with-task-scope` is cooperative.
  `with-interruptible-scope` supports explicit preemptive interruption, and
  `with-timeout` adds a deadline through the same mechanism. Body condition
  handlers do not observe the boundary's condition; user cleanup can replace
  the pending transfer. SBCL can defer delivery during
  `without-interrupts` and garbage collection; safe resource cleanup still
  depends on the caller's protection of acquisition and cleanup-state updates.
  See [API reference](api.md#interruptible-scopes).
- Objects are scoped to one SBCL image and are not serializable across
  processes or machines.
