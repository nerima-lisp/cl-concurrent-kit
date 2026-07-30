# cl-concurrent-kit

[![CI](https://github.com/nerima-lisp/cl-concurrent-kit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/nerima-lisp/cl-concurrent-kit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Documentation](https://img.shields.io/badge/docs-MkDocs%20Material-0a7a5a)](https://nerima-lisp.github.io/cl-concurrent-kit/)

A dependency-free, SBCL-only concurrency toolkit. It wraps `sb-thread` into
the primitives a portability layer such as bordeaux-threads would offer
(threads, locks, condition variables, semaphores), then builds the
concurrency shapes familiar from modern languages on top: promises/futures,
CSP channels with `select`, a fixed-size executor, and structured-concurrency
scopes with cooperative cancellation.

Full documentation is published at <https://nerima-lisp.github.io/cl-concurrent-kit/>.
The source for that site lives in [docs/src/](docs/src/).

## Quick Start

```lisp
(asdf:load-system "cl-concurrent-kit")

(cl-concurrent-kit:with-task-scope (scope)
  (let ((f (cl-concurrent-kit:spawn scope (lambda () (+ 1 2)))))
    (cl-concurrent-kit:await f)))
;; => 3
```

## Install

```nix
# flake.nix
inputs.cl-concurrent-kit = {
  url = "github:nerima-lisp/cl-concurrent-kit/v0.2.0";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Note the pinned tag. Consumers inside this org must pin a release tag rather
than follow the default branch.

## Documentation

- [Getting started](https://nerima-lisp.github.io/cl-concurrent-kit/getting-started/)
- [API reference](https://nerima-lisp.github.io/cl-concurrent-kit/api-reference/)
- [Architecture](https://nerima-lisp.github.io/cl-concurrent-kit/architecture/)

## Development

```sh
nix develop          # SBCL with CL_SOURCE_REGISTRY already set
nix run .#test       # run the test suite
nix run .#coverage -- ./coverage  # write HTML and LCOV coverage reports to ./coverage
nix run .#benchmark -- 1000000  # report hot-path throughput as TSV
nix flake check      # tests + coverage + formatting + docs, the same gate CI uses
nix fmt              # format Nix sources (treefmt)
```

`benchmark` warms each workload, takes five post-GC samples, and reports the
median TSV throughput for atomic-counter increment, a capacity-one buffered
channel round trip, an immediately ready `SELECT` receive, and an executor
submit/await round trip. Each workload validates its result. CI checks the
output shape rather than a machine-specific throughput threshold; compare
numbers only on like-for-like SBCL versions, CPU governors, and hardware.

Tests live in `t/` and run under [cl-weave](https://github.com/nerima-lisp/cl-weave),
the org's test framework.

## Contributing

See the org-wide [CONTRIBUTING](https://github.com/nerima-lisp/.github/blob/main/CONTRIBUTING.md)
guide and the [package standard](https://github.com/nerima-lisp/.github/blob/main/PACKAGE_STANDARD.md).

## Support

See [SUPPORT](https://github.com/nerima-lisp/.github/blob/main/SUPPORT.md).

## License

MIT. See [LICENSE](LICENSE).
