# Compatibility

## Implementation and dependencies

The library targets SBCL. Its Nix CI uses SBCL 2.6.6; the macOS clock caveat in
[Architecture](architecture.md) describes SBCL 2.6.8 specifically. Its runtime
dependency is [cl-date-kit](https://github.com/nerima-lisp/cl-date-kit). The test system
additionally uses [cl-weave](https://github.com/nerima-lisp/cl-weave).
Benchmark scripts use [cl-cli](https://github.com/nerima-lisp/cl-cli), which
uses [cl-host-kit](https://github.com/nerima-lisp/cl-host-kit) on SBCL.

The implementation uses SBCL's native thread and synchronization facilities
in `src/primitives.lisp`. Porting to another Common Lisp implementation
requires replacing that layer; the higher-level components do not reference
`sb-*` packages directly.

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
  Use `with-timeout` when an operation must be interrupted preemptively; see
  [Architecture](architecture.md#threading-primitives) and
  [Architecture](architecture.md#task-scopes-and-cancellation).
- Objects are scoped to one SBCL image and are not serializable across
  processes or machines.
