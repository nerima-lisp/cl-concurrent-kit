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

`AWAIT`, `SEND`, and `RECV` take `:TIMEOUT` -- a `cl-date-kit:duration` --
and signal `OPERATION-TIMED-OUT` rather than waiting indefinitely. `SELECT`
instead uses its `(:timeout duration () body...)` clause to run a fallback
expression. For lifecycle waits, pass `:TIMEOUT` with `:WAIT T` to
`SHUTDOWN-EXECUTOR`, or to `WITH-TASK-SCOPE` to bound child cleanup:

```lisp
(handler-case (cl-concurrent-kit:await promise
                                       :timeout (cl-date-kit:duration-of-seconds 5))
  (cl-concurrent-kit:operation-timed-out ()
    :gave-up))
```

```lisp
(cl-concurrent-kit:shutdown-executor executor
                                     :wait t
                                     :timeout (cl-date-kit:duration-of-seconds 5))

(cl-concurrent-kit:with-task-scope (scope :timeout (cl-date-kit:duration-of-seconds 5))
  (cl-concurrent-kit:spawn scope #'run-job))
```

## Racing several channels with SELECT

```lisp
(cl-concurrent-kit:select
  ((recv fast-channel) (value) (list :fast value))
  ((recv slow-channel) (value) (list :slow value))
  (:timeout (cl-date-kit:duration-of-seconds 2) () :neither-arrived))
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

## Chaining promises without blocking

`PROMISE-THEN` composes by continuation: each call registers a callback and
returns a new promise immediately, so a chain never blocks the thread that
builds it.

```lisp
(let* ((fetched (cl-concurrent-kit:future (fetch url)))
       (parsed (cl-concurrent-kit:promise-then fetched #'parse-response))
       (recorded (cl-concurrent-kit:promise-then
                  parsed
                  (lambda (value) (record value) value)
                  (lambda (condition) (log-fetch-failure url condition) nil))))
  (cl-concurrent-kit:await recorded))
```

The two-argument form of `PROMISE-THEN` propagates a failed input's condition
unchanged; the three-argument form above intercepts it instead, so a fetch or
parse failure is logged and turned into `NIL` rather than re-signaled to
`AWAIT`.

## Bounding how long a scope waits for stragglers

`WITH-TASK-SCOPE`'s `:TIMEOUT` -- a `cl-date-kit:duration` -- bounds only the
cleanup wait -- the time between the body finishing (normally or by error)
and every spawned child actually having stopped -- not the body itself:

```lisp
(handler-case
    (cl-concurrent-kit:with-task-scope (scope :timeout (cl-date-kit:duration-of-seconds 5))
      (cl-concurrent-kit:spawn scope #'slow-cleanup-task))
  (cl-concurrent-kit:operation-timed-out ()
    (log-warning "a scope child did not honor cancellation within 5s")))
```

On expiry, every child still running is cancelled the same cooperative way a
sibling failure would cancel them -- `CHECK-CANCELLED` is still what a child
must call to actually notice.

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

## Backpressure with a bounded executor

`MAKE-EXECUTOR`'s `:QUEUE-CAPACITY` turns an unbounded queue into a bound a
fast producer cannot outrun. `TRY-SUBMIT` reports whether work was accepted
without needing to `AWAIT` a rejected promise just to find out:

```lisp
(let ((executor (cl-concurrent-kit:make-executor :size 4 :queue-capacity 100)))
  (unwind-protect
      (dolist (job jobs)
        (multiple-value-bind (promise accepted-p) (cl-concurrent-kit:try-submit executor job)
          (declare (ignore promise))
          (unless accepted-p (requeue-later job))))
    (cl-concurrent-kit:shutdown-executor executor :wait t)))
```

`WITH-EXECUTOR` covers the common case of `MAKE-EXECUTOR` immediately
followed by an `UNWIND-PROTECT`'d `SHUTDOWN-EXECUTOR`:

```lisp
(cl-concurrent-kit:with-executor (executor :size 4)
  (mapcar #'cl-concurrent-kit:await
          (loop for job in jobs collect (cl-concurrent-kit:submit executor job))))
```

## Waiting for the first success, or every failure

`PROMISE-ALL` fails fast on the first rejection, mirroring `MAPCAR` over
`AWAIT`; `PROMISE-ANY` instead resolves as soon as any input fulfills, and
only fails -- with `PROMISE-ALL-FAILED` -- once every input has:

```lisp
(cl-concurrent-kit:await
 (cl-concurrent-kit:promise-any
  (mapcar (lambda (mirror) (cl-concurrent-kit:future (fetch mirror))) mirrors)))
```

## Coordinating start with a latch, phases with a barrier

`COUNTDOWN-LATCH` holds several workers at a starting line until a shared
setup step finishes:

```lisp
(let ((ready (cl-concurrent-kit:make-countdown-latch 1)))
  (cl-concurrent-kit:with-task-scope (scope)
    (dotimes (i worker-count)
      (cl-concurrent-kit:spawn
       scope
       (lambda ()
         (cl-concurrent-kit:await-latch ready :scope scope)
         (run-worker i))))
    (setup-shared-state)
    (cl-concurrent-kit:count-down ready)))
```

`BARRIER` instead resynchronizes a fixed set of parties at the end of every
phase, in a loop, since it releases and starts a fresh generation on its own:

```lisp
(let ((barrier (cl-concurrent-kit:make-barrier worker-count)))
  (cl-concurrent-kit:with-task-scope (scope)
    (dotimes (i worker-count)
      (cl-concurrent-kit:spawn
       scope
       (lambda ()
         (dotimes (phase phase-count)
           (run-phase i phase)
           (cl-concurrent-kit:await-barrier barrier :scope scope)))))))
```

## A reactive stream pipeline

The `CHANNEL-*` stream operators chain like the manual pipeline stage above,
without hand-writing each stage's read/transform/write loop:

```lisp
(cl-concurrent-kit:with-task-scope (scope)
  (let* ((source (cl-concurrent-kit:channel-from-sequence readings :scope scope))
         (valid (cl-concurrent-kit:channel-filter #'valid-reading-p source :scope scope))
         (smoothed (cl-concurrent-kit:channel-debounce 0.1 valid :scope scope))
         (results (cl-concurrent-kit:channel-map #'analyze smoothed :scope scope)))
    (cl-concurrent-kit:await (cl-concurrent-kit:channel-collect results :scope scope))))
```

Passing the same `:SCOPE` to every stage means cancelling it -- e.g. because
an earlier stage failed -- closes every stage's output promptly rather than
leaving a downstream `RECV` blocked on a producer that will never write to it
again.
