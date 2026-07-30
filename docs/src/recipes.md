# Recipes

## Fan-out / fan-in with an executor

```lisp
(let* ((executor (cl-concurrent-kit:make-executor :size 4))
       (results (loop for url in urls
                       collect (cl-concurrent-kit:submit
                                executor
                                (let ((url url)) (lambda () (fetch url)))))))
  (unwind-protect
      (mapcar #'cl-concurrent-kit:await results)
    (cl-concurrent-kit:shutdown-executor executor :wait t)))
```

Note the `(let ((url url)) ...)` rebind: `LOOP`'s `FOR` mutates one binding
in place rather than creating a fresh one per iteration, so every closure
that does not rebind its loop variable would end up seeing whatever value
the variable reached by the time a worker thread got around to running it.

## Bounded blocking operations

`AWAIT`, `SEND`, and `RECV` take `:TIMEOUT` and signal
`OPERATION-TIMED-OUT` rather than waiting indefinitely. `SELECT` instead
uses its `(:timeout seconds () body...)` clause to run a fallback expression.
For lifecycle waits, pass `:TIMEOUT` with `:WAIT T` to
`SHUTDOWN-EXECUTOR`, or to `WITH-TASK-SCOPE` to bound child cleanup:

```lisp
(handler-case (cl-concurrent-kit:await promise :timeout 5)
  (cl-concurrent-kit:operation-timed-out ()
    :gave-up))
```

```lisp
(cl-concurrent-kit:shutdown-executor executor :wait t :timeout 5)

(cl-concurrent-kit:with-task-scope (scope :timeout 5)
  (cl-concurrent-kit:spawn scope #'run-job))
```

## Racing several channels with SELECT

```lisp
(cl-concurrent-kit:select
  ((recv fast-channel) (value) (list :fast value))
  ((recv slow-channel) (value) (list :slow value))
  (:timeout 2 () :neither-arrived))
```

## A pipeline stage

Channels compose into pipelines the way Go's do: each stage reads from an
input channel and writes to an output channel it owns.

Use `SPAWN` to make each stage a tracked child of `WITH-TASK-SCOPE`. Pass
`:EXECUTOR` when several stages should share a bounded worker pool.

```lisp
(defun stage (scope in out transform &key executor)
  (cl-concurrent-kit:spawn
   scope
   (lambda ()
    (loop
      (multiple-value-bind (value ok-p) (cl-concurrent-kit:recv in)
        (unless ok-p (cl-concurrent-kit:close-channel out) (return))
        (cl-concurrent-kit:send out (funcall transform value)))))
   :executor executor))
```

## Cooperative cancellation inside a scope

`CHECK-CANCELLED` only does anything at the point it is called, so call it
wherever your task can safely stop -- typically the top of a loop:

```lisp
(cl-concurrent-kit:with-task-scope (scope)
  (cl-concurrent-kit:spawn scope (lambda () (error "something went wrong")))
  (cl-concurrent-kit:spawn
   scope
   (lambda ()
     (loop for chunk in work-items
           do (cl-concurrent-kit:check-cancelled scope)
              (process chunk)))))
```

If the first task fails, the second observes `TASK-CANCELLED` at its next
`CHECK-CANCELLED` and unwinds instead of processing the remaining items.
