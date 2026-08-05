# Getting started

## Install

```nix
# flake.nix
inputs.cl-concurrent-kit = {
  url = "github:nerima-lisp/cl-concurrent-kit/v0.6.1";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Or, from a plain ASDF setup, clone the repository (and its `cl-boundary-kit`/
`cl-date-kit` dependencies) somewhere on your `CL_SOURCE_REGISTRY` and:

```lisp
(asdf:load-system "cl-concurrent-kit")
```

## A future

```lisp
(cl-concurrent-kit:await (cl-concurrent-kit:future (+ 1 2 3)))
;; => 6
```

## A channel

```lisp
(let ((channel (cl-concurrent-kit:make-channel)))
  (cl-concurrent-kit:future (cl-concurrent-kit:send channel :hello))
  (cl-concurrent-kit:recv channel))
;; => :HELLO, T
```

## A structured-concurrency scope

```lisp
(cl-concurrent-kit:with-task-scope (scope)
  (let ((a (cl-concurrent-kit:spawn scope (lambda () (+ 1 2))))
        (b (cl-concurrent-kit:spawn scope (lambda () (* 3 4)))))
    (+ (cl-concurrent-kit:await a) (cl-concurrent-kit:await b))))
;; => 15, and both tasks are guaranteed to have finished before this returns.
```

## A timeout

Every `:TIMEOUT` argument in this library takes a `cl-date-kit:duration`,
not a raw number of seconds:

```lisp
(cl-concurrent-kit:await (cl-concurrent-kit:future (sleep 5))
                          :timeout (cl-date-kit:duration-of-millis 50))
;; signals CL-CONCURRENT-KIT:OPERATION-TIMED-OUT
```

Next: [Core concepts](guide/core-concepts.md) for the ideas behind each layer, or
[Recipes](guide/recipes.md) for more worked examples.
