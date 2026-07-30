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

## A timeout on any single operation

Every blocking operation (`AWAIT`, `SEND`, `RECV`, `SELECT`'s implicit wait)
takes a timeout and signals `OPERATION-TIMED-OUT` rather than hanging:

```lisp
(handler-case (cl-concurrent-kit:await promise :timeout 5)
  (cl-concurrent-kit:operation-timed-out ()
    :gave-up))
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

```lisp
(defun stage (in out transform)
  (cl-concurrent-kit:future
    (loop
      (multiple-value-bind (value ok-p) (cl-concurrent-kit:recv in)
        (unless ok-p (cl-concurrent-kit:close-channel out) (return))
        (cl-concurrent-kit:send out (funcall transform value))))))
```

## Waiting for every result, failures included

`AWAIT` re-signals a failed promise's condition, so gathering several
promises with a plain `MAPCAR` over `AWAIT` aborts on the first failure.
`PROMISE-ALL-SETTLED` instead waits for every input to settle and hands back
one `PROMISE-SETTLEMENT` per input, in order, regardless of outcome:

```lisp
(let ((settlements (cl-concurrent-kit:await
                     (cl-concurrent-kit:promise-all-settled
                      (mapcar (lambda (url) (cl-concurrent-kit:future (fetch url)))
                              urls)))))
  (loop for settlement in settlements
        for url in urls
        do (ecase (cl-concurrent-kit:promise-settlement-state settlement)
             (:fulfilled (record-success url (cl-concurrent-kit:promise-settlement-value settlement)))
             (:failed (record-failure url (cl-concurrent-kit:promise-settlement-condition settlement))))))
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
