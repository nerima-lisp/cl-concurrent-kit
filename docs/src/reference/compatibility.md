# Compatibility

- **Implementation:** SBCL only. Tested against SBCL 2.6.0.
- **Dependencies:** two real runtime dependencies, both consumed directly
  with no wrapper type or adapter layer --
  [cl-boundary-kit](https://github.com/nerima-lisp/cl-boundary-kit) v2.3.0
  (the injectable `CLOCK` behind `src/primitives.lisp`'s deadline
  arithmetic, exposed on the `*CLOCK*` special variable) and
  [cl-date-kit](https://github.com/nerima-lisp/cl-date-kit) v1.0.0 (the
  `DURATION` type every public `:TIMEOUT` argument accepts). Both are named
  in `cl-concurrent-kit.asd`'s main-system `:depends-on`, not just the test
  system's. `cl-concurrent-kit/test` additionally depends on
  [cl-weave](https://github.com/nerima-lisp/cl-weave) v1.3.0, test-only --
  its test DSL (`describe`/`it`/`expect`/`signals`), property-based testing
  and fuzzing (`it-property`, `it-fuzz`, `gen-integer`, `gen-list`,
  `gen-boolean`), table-driven suites (`it-each`), fixtures (`around-each`),
  mocking (`with-replaced-function`), concurrent execution
  (`describe-concurrent`), soft assertions (`with-soft-assertions`,
  reporting every failing `expect` in an `it` block instead of stopping at
  the first), and benchmark facility (`benchmark`, used by
  `benchmarks/run-benchmarks.lisp`) are all in active use, not just the
  assertion macros. That same script additionally depends on
  [cl-cli](https://github.com/nerima-lisp/cl-cli) v1.2.0,
  benchmark-tooling-only, for its `--only`/scale argument parsing, and
  transitively on [cl-host-kit](https://github.com/nerima-lisp/cl-host-kit)
  v0.3.1 (both cl-cli's own SBCL dependency and cl-boundary-kit's own
  real-boundary backend) -- none of `cl-weave`, `cl-cli`, or `cl-host-kit`
  is reachable from `cl-concurrent-kit`'s own `:depends-on`, only from
  `flake.nix`'s `CL_SOURCE_REGISTRY` for the relevant script/check/test
  system.
  `flake.nix` itself is built with
  [cl-nix-forge](https://github.com/nerima-lisp/cl-nix-forge), the org's Nix
  packaging library -- a build-time-only, Nix-level dependency with no Lisp
  component. A fifth nerima-lisp tool,
  [paredit-cli](https://github.com/nerima-lisp/paredit-cli), is not a
  dependency at all in the ASDF/Nix sense -- it never appears in
  `:depends-on`, `flake.nix`, or `CL_SOURCE_REGISTRY` -- but is the
  structure-aware refactoring tool this project's own source history was
  edited with throughout: renames (`refactor rename-function`), balance
  validation after every structural edit (`inspect check`), and definition
  discovery (`inspect definitions`) all ran through it rather than by hand.
- **Platforms:** `x86_64-linux` is the only platform CI actually gates.
  `aarch64-darwin` is also declared, for `nix develop`/`nix build` on the
  development machine -- dropped briefly on 2026-08-01 for carrying no CI
  gate, then re-declared on 2026-08-02 once the org's own
  [PACKAGE_STANDARD.md](https://github.com/nerima-lisp/.github/blob/main/PACKAGE_STANDARD.md)
  accepted that trade-off explicitly rather than requiring every declared
  system to be CI-gated. `aarch64-linux` and `x86_64-darwin` are nobody's
  verification and stay undeclared. See `flake.nix`.

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

`flake.lock` pins `cl-boundary-kit`, `cl-date-kit`, `cl-weave`, `cl-cli`,
`cl-host-kit`, and `cl-nix-forge` to specific tagged releases (bumped by
hand when this package adopts a new one) and `nixpkgs`/`treefmt-nix`
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
- **Timeout audit:** every place this project itself runs a command or blocks
  on a result has an explicit bound, checked directly rather than assumed:
  - `flake.nix`'s three shell invocations (`checks.coverage-lcov`,
    `checks.benchmark`, `apps.benchmark`) each wrap their `sbcl` call in
    `timeout --signal=KILL <N>s`.
  - Every job in every workflow under `.github/workflows/` (`ci.yml`,
    `docs.yml`'s two jobs, `flake-update.yml`, `release.yml`) declares its own
    `timeout-minutes:` -- there is no job relying on GitHub's default.
  - The test suite has a global backstop (`run-all :timeout-ms 20000` in
    `t/package.lisp`) bounding every single test regardless of what it
    does. An individual blocking `recv`/`await`/`select` additionally
    carries its own explicit `:timeout` wherever a test needs to assert
    real `OPERATION-TIMED-OUT` behavior, or where a genuinely unbounded
    wait would otherwise only fail slowly (at the 20-second global bound)
    instead of immediately at the point something actually went wrong. A
    bare `recv`/`await` with no `:timeout` of its own relies on that
    global backstop rather than going unbounded -- and, in every such
    case in this suite, the value it waits for is already available --
    sent, cancelled, or buffered earlier in the same test body -- so the
    call resolves synchronously in practice and the backstop is never hit.
