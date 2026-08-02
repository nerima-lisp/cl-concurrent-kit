# Compatibility

- **Implementation:** SBCL only. Tested against SBCL 2.6.0.
- **Dependencies:** none at runtime. `cl-concurrent-kit/test` depends on
  [cl-weave](https://github.com/nerima-lisp/cl-weave) v1.1.0, test-only.
  `flake.nix` itself is built with
  [cl-nix-forge](https://github.com/nerima-lisp/cl-nix-forge), the org's Nix
  packaging library -- a build-time-only, Nix-level dependency with no Lisp
  component.
- **Platforms:** `x86_64-linux` only, verified by CI. `aarch64-darwin` was
  dropped on 2026-08-01: its only gate was the maintainer's local
  `nix flake check`, which nobody can observe being skipped. `nix develop` and
  `nix build` therefore do not work on macOS. See `flake.nix`.

cl-concurrent-kit wraps `sb-thread` and `sb-ext` directly rather than
depending on bordeaux-threads; see [Architecture](architecture.md) for why.
Porting to another implementation would mean reimplementing
`src/primitives.lisp` against that implementation's native thread API --
everything above that layer (`promise`, `channel`, `select`, `executor`,
`scope`) is portable Common Lisp with no `sb-*` references.

## Stability

The public API is exactly `src/package.lisp`'s `:export` list -- nothing
reached only through a package-qualified `cl-concurrent-kit::` symbol is
covered by semantic versioning. Every exported symbol is exercised by at
least one test in `t/`, and `nix flake check` (tests, docs, formatting,
coverage) gates every merge to `main` and every tagged release; see
[.github/workflows/ci.yml](https://github.com/nerima-lisp/cl-concurrent-kit/blob/main/.github/workflows/ci.yml)
and [release.yml](https://github.com/nerima-lisp/cl-concurrent-kit/blob/main/.github/workflows/release.yml).

`flake.lock` pins `cl-weave` and `cl-nix-forge` to specific tagged releases
(bumped by hand when this package adopts a new one) and `nixpkgs`/`treefmt-nix`
to a commit refreshed automatically by
[flake-update.yml](https://github.com/nerima-lisp/cl-concurrent-kit/blob/main/.github/workflows/flake-update.yml)'s
weekly cron, each update going through the same `nix flake check` gate as any
other change before merging.

## Production readiness

This is a library, loaded into a caller's own SBCL image -- there is no
service to deploy and no SLA to publish; what a caller integrating it needs
to know is below. (For round-trip overhead per primitive, run
`benchmarks/run-benchmarks.lisp`, described in the repository's own
top-level README.)

- **Error handling:** every blocking operation that accepts `:timeout` signals
  `operation-timed-out` (never returns a sentinel value) on expiry; every
  other failure mode is its own condition (`promise-already-fulfilled`,
  `channel-closed`, `task-cancelled`, `scope-error`, `latch-count-underflow`,
  `barrier-broken`, `promise-cancelled`, `promise-empty-input`,
  `promise-all-failed`, `executor-queue-full`) subclassing
  `cl-concurrent-kit-error`, so a caller can catch that one base condition to
  handle any failure this library signals without enumerating each one.
- **Thread safety:** every public struct (`promise`, `channel`, `executor`,
  `task-scope`, `countdown-latch`, `barrier`) owns its own lock and is safe
  to share across threads through its documented operations only; none of
  them is safe to mutate through slot accessors directly (all writer
  accessors are internal, `%`-prefixed).
- **Resource cleanup:** `make-executor` starts worker threads that outlive
  the call until `shutdown-executor` is called -- there is no finalizer, by
  design, matching `sb-thread`'s own contract; a long-running process that
  creates executors without shutting them down leaks threads exactly as it
  would leak any other unclosed resource. `with-task-scope` and `future`
  have no equivalent leak: every thread either one starts is guaranteed to
  have been joined (structured concurrency) or was never blocked on
  externally (future's own thread exits on its own).
- **Known limitation:** cancellation (`check-cancelled`, `with-task-scope`)
  is cooperative, not preemptive -- see
  [Architecture](architecture.md#structured-concurrency-why-the-bodys-own-error-is-never-wrapped)
  for why forcing it would cost the guarantee a scope exists to make. Where a
  body really must be bounded whatever it is doing, `with-timeout` is the
  preemptive escape hatch (it interrupts the thread outright), with the
  asynchronous-unwind caveat that comes with one:
  [Architecture](architecture.md#preemptive-with-timeout-cooperative-scopes).
- **Scope:** single SBCL image only. Nothing here coordinates across OS
  processes or machines; `promise`/`channel`/`executor`/`task-scope` objects
  are not serializable and sharing one across images is not a supported use.
