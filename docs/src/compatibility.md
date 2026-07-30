# Compatibility

- **Implementation:** SBCL only. Tested against SBCL 2.6.0.
- **Dependencies:** none at runtime. `cl-concurrent-kit/test` depends on
  [cl-weave](https://github.com/nerima-lisp/cl-weave) v1.1.0, test-only.
  `flake.nix` itself is built with
  [cl-nix-forge](https://github.com/nerima-lisp/cl-nix-forge), the org's Nix
  packaging library -- a build-time-only, Nix-level dependency with no Lisp
  component.
- **Platforms:** `x86_64-linux` (verified by CI) and `aarch64-darwin`
  (verified by the maintainer's local `nix flake check`). See `flake.nix`.

cl-concurrent-kit wraps `sb-thread` and `sb-ext` directly rather than
depending on bordeaux-threads; see [Architecture](architecture.md) for why.
Porting to another implementation would mean reimplementing
`src/primitives.lisp` against that implementation's native thread API --
everything above that layer (`promise`, `channel`, `select`, `executor`,
`scope`) is portable Common Lisp with no `sb-*` references.
