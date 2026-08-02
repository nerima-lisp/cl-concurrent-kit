# cl-concurrent-kit

[![CI](https://github.com/nerima-lisp/cl-concurrent-kit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/nerima-lisp/cl-concurrent-kit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Documentation](https://img.shields.io/badge/docs-MkDocs%20Material-0a7a5a)](https://nerima-lisp.github.io/cl-concurrent-kit/)

A dependency-free, SBCL-only concurrency toolkit. It wraps `sb-thread` into
the primitives a portability layer such as bordeaux-threads would offer
(threads, locks, condition variables, semaphores), then builds the
concurrency shapes familiar from modern languages on top: promises/futures
with `.then()`-style combinators, CSP channels with `select`, a fixed-size
executor with bounded queues and observability, structured-concurrency
scopes with cooperative cancellation, a preemptive `WITH-TIMEOUT` for
bounding an arbitrary body, countdown latches and cyclic barriers, and a
reactive stream layer of `CHANNEL-*` operators (map/filter/merge/zip and the
rest) built on top of channels.

Full documentation is published at <https://nerima-lisp.github.io/cl-concurrent-kit/>.
The source for that site lives in [docs/src/](docs/src/).

## Quick Start

```lisp
(asdf:load-system "cl-concurrent-kit")

(cl-concurrent-kit:with-task-scope (scope)
  (let ((f (cl-concurrent-kit:spawn scope (lambda () (+ 1 2)))))
    (cl-concurrent-kit:await f)))
;; => 3

;; PROMISE-THEN composes promises by continuation, never by blocking:
(cl-concurrent-kit:await
 (cl-concurrent-kit:promise-then (cl-concurrent-kit:future (+ 1 2))
                                  (lambda (value) (* value 10))))
;; => 30
```

## Install

```nix
# flake.nix
inputs.cl-concurrent-kit = {
  url = "github:nerima-lisp/cl-concurrent-kit/v0.3.0";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Note the pinned tag. Consumers inside this org must pin a release tag rather
than follow the default branch.

## Documentation

- [Getting started](https://nerima-lisp.github.io/cl-concurrent-kit/getting-started/)
- [API reference](https://nerima-lisp.github.io/cl-concurrent-kit/reference/api/)
- [Architecture](https://nerima-lisp.github.io/cl-concurrent-kit/reference/architecture/)

## Development

```sh
nix develop          # SBCL with CL_SOURCE_REGISTRY already set
nix run .#test       # run the test suite
nix build .#coverage # an sb-cover HTML report as the build's $out
nix run .#benchmark -- 1000000  # report each primitive's round-trip overhead
nix flake check      # tests + coverage + formatting + docs, the same gate CI uses
nix fmt              # format Nix sources (treefmt)
```

Outside Nix, `sbcl --script run-coverage.lisp [output-dir]` writes the same
HTML report plus an `lcov.info` next to it, for tooling that reads LCOV
directly; `nix flake check`'s `coverage-lcov` check runs the same script and
additionally fails the build if any source file falls under this project's
own coverage bar, rather than only rendering a number someone has to
remember to look at.

`sb-cover` instruments code as it runs, so a file's own `IN-PACKAGE` form, its
`DEFSTRUCT` slot-default initializers, and any `DEFMACRO`'s body all run once
at compile/macroexpansion time -- before `sb-cover` starts recording -- and
show up as "not executed" no matter how many times their effect (a
fully-covered `DEFINE-CONDITION`, a channel actually being locked) is
exercised elsewhere. Chasing 100% on the *expression* column there would mean
chasing the instrumentation, not the behavior; the *branch* column is the one
worth holding at 100%.

Tests live in `t/` and run under [cl-weave](https://github.com/nerima-lisp/cl-weave),
the org's test framework.

`nix develop -c sbcl --script benchmarks/run-benchmarks.lisp` reports each
primitive's own round-trip overhead (channel send/recv, promise
deliver/await, executor submit/await, scope spawn/await, ...) using
cl-weave's `benchmark`, the same tool the org's other repositories use, so
the numbers are directly comparable across them. Argument parsing is
[cl-cli](https://github.com/nerima-lisp/cl-cli): `-- --only channel` runs
only the benchmarks whose name contains `channel`, and a trailing number
(`-- 0.1`) scales every benchmark's own iteration count by that factor,
for a quick pass instead of the full suite.

## Contributing

See the org-wide [CONTRIBUTING](https://github.com/nerima-lisp/.github/blob/main/CONTRIBUTING.md)
guide and the [package standard](https://github.com/nerima-lisp/.github/blob/main/PACKAGE_STANDARD.md).

## Support

See [SUPPORT](https://github.com/nerima-lisp/.github/blob/main/SUPPORT.md).

## License

MIT. See [LICENSE](LICENSE).
