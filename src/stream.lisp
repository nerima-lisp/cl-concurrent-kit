;;;; src/stream.lisp
;;;;
;;;; Stream stages built from CHANNEL: a stage owns its output channel and
;;;; exposes its worker promise so a caller outside a task scope can observe
;;;; a transformation failure instead of silently reading from a channel that
;;;; simply went quiet. Every stage below takes an optional :SCOPE argument,
;;;; passed explicitly exactly as SPAWN's own SCOPE argument is (never read
;;;; from a dynamic variable) -- with SCOPE, the stage's worker is a tracked
;;;; child and observes SCOPE's cancellation cooperatively, the same way
;;;; CHECK-CANCELLED works anywhere else in this package. Because CHANNEL's
;;;; own RECV/SEND have no SCOPE argument, a stage already blocked inside one
;;;; cannot be woken early by cancellation -- it is checked between values,
;;;; not mid-wait, the same inherent limit as a plain (SLEEP N) inside any
;;;; other SPAWNed function.
(in-package #:cl-concurrent-kit)

(defun %close-stage-outputs (outputs)
  "Close every stage-owned output channel in OUTPUTS (a list)."
  (dolist (output outputs)
    (close-channel output)))

(defmacro %with-closed-stage-outputs ((outputs) &body body)
  "Run BODY and close OUTPUTS (a list) on every exit path."
  `(unwind-protect (progn ,@body)
     (%close-stage-outputs ,outputs)))

(defun %start-channel-stage (function &key scope executor outputs)
  "Run FUNCTION with the requested ownership model -- SCOPE (a tracked
child, optionally also on EXECUTOR), EXECUTOR alone, or neither (a dedicated
thread via FUTURE) -- and return its promise.

If SCOPE is supplied, a waker registered on it closes OUTPUTS immediately
should SCOPE already be (or become) cancelled before FUNCTION ever actually
starts running -- e.g. a still-queued EXECUTOR task SPAWN cancels outright
without running. FUNCTION itself removes that waker as the first thing it
does once it does start, since from that point its own UNWIND-PROTECT (via
%WITH-CLOSED-STAGE-OUTPUTS) is what closes OUTPUTS on any later exit,
including SCOPE cancelling it mid-run.

If starting the stage fails synchronously, OUTPUTS are closed before
returning a failed promise, so a consumer never waits on a worker that never
started."
  (let ((waker (and scope (lambda () (%close-stage-outputs outputs)))))
    (when waker
      (%scope-add-waker scope waker))
    (flet ((unregister-waker ()
             (when waker
               (%scope-remove-waker scope waker))))
      (handler-case
          (cond
            (scope
             (spawn scope
                    (lambda ()
                      (unregister-waker)
                      (funcall function))
                    :executor executor))
            (executor (submit executor function))
            (t (%future function)))
        (error (condition)
          (unregister-waker)
          (%close-stage-outputs outputs)
          (let ((promise (make-promise)))
            (deliver-error promise condition)))))))

(defun %make-channel-emitting-stage (input buffer-size scope executor emit-values)
  "Create a stage that calls EMIT-VALUES for every value received from INPUT.

EMIT-VALUES receives VALUE and a single-argument EMIT function; EMIT sends
one value to the output channel, preserving stage ordering and backpressure."
  (check-type input channel)
  (let ((output (make-channel :buffer-size buffer-size)))
    (values
     output
     (%start-channel-stage
      (lambda ()
        (%with-closed-stage-outputs ((list output))
          (loop
            (when scope (check-cancelled scope))
            (multiple-value-bind (value received-p) (recv input)
              (unless received-p (return))
              (funcall emit-values value (lambda (result) (send output result)))))))
      :scope scope :executor executor :outputs (list output)))))

(defun %make-channel-source (buffer-size scope executor produce-values)
  "Create a source stage that calls PRODUCE-VALUES with its EMIT function.

The source owns and closes its output channel. EMIT sends one value while
preserving backpressure."
  (let ((output (make-channel :buffer-size buffer-size)))
    (values
     output
     (%start-channel-stage
      (lambda ()
        (%with-closed-stage-outputs ((list output))
          (funcall produce-values (lambda (value) (send output value)))
          nil))
      :scope scope :executor executor :outputs (list output)))))

(defmacro channel-producer ((emit &key (buffer-size 0) scope executor) &body body)
  "Create an asynchronous channel source whose BODY sends values through
EMIT, a lexical single-argument function. BODY runs on a background task and
may call EMIT repeatedly; each call preserves backpressure. Returns two
values: the output channel and a completion promise."
  `(%make-channel-source ,buffer-size ,scope ,executor (lambda (,emit) ,@body)))

(defun %make-channel-stage (input buffer-size scope executor transform)
  "Create a 0-or-1-output stage from TRANSFORM, which returns two values: an
output value and whether to emit it."
  (%make-channel-emitting-stage
   input buffer-size scope executor
   (lambda (value emit)
     (multiple-value-bind (result emit-p) (funcall transform value)
       (when emit-p (funcall emit result))))))

(defun channel-from-sequence (sequence &key (buffer-size 0) scope executor)
  "Create a finite channel source from a snapshot of SEQUENCE, taken before
the producer starts so later mutations to SEQUENCE do not affect emitted
values. Returns two values: the output channel and a completion promise."
  (check-type sequence sequence)
  (let ((snapshot (copy-seq sequence)))
    (%make-channel-source buffer-size scope executor (lambda (emit) (map nil emit snapshot)))))

(defun channel-map (function input &key (buffer-size 0) scope executor)
  "Apply FUNCTION to every value received from INPUT on a background task.

Returns two values: an output channel and a completion promise. The output
channel closes once INPUT is drained, including when FUNCTION signals or the
optional SCOPE is cancelled -- await the completion promise to observe a
failure outside a task scope. With SCOPE, the stage is a tracked child; with
EXECUTOR, it runs on that executor."
  (%make-channel-stage input buffer-size scope executor
                        (lambda (value) (values (funcall function value) t))))

(defun channel-keep (function input &key (buffer-size 0) scope executor)
  "Apply FUNCTION to each INPUT value and forward only its non-NIL results.

Returns two values: an output channel and a completion promise. Ownership,
closure, cancellation, and executor behavior are the same as CHANNEL-MAP."
  (check-type function function)
  (%make-channel-stage input buffer-size scope executor
                        (lambda (value)
                          (let ((result (funcall function value)))
                            (values result result)))))

(defun channel-filter (predicate input &key (buffer-size 0) scope executor)
  "Forward INPUT values for which PREDICATE is truthy.

Returns two values: an output channel and a completion promise. Ownership,
closure, cancellation, and executor behavior are the same as CHANNEL-MAP."
  (%make-channel-stage input buffer-size scope executor
                        (lambda (value) (values value (funcall predicate value)))))

(defun channel-distinct-until-changed (input &key (test (function eql)) (key (function identity))
                                        (buffer-size 0) scope executor)
  "Forward the first INPUT value, and any later value whose KEY differs from
the prior forwarded value's KEY under TEST.

Returns two values: an output channel and a completion promise. Ownership,
closure, cancellation, and executor behavior are the same as CHANNEL-MAP."
  (check-type input channel)
  (check-type test function)
  (check-type key function)
  (let ((previous-key nil)
        (previous-p nil))
    (%make-channel-stage
     input buffer-size scope executor
     (lambda (value)
       (let* ((current-key (funcall key value))
              (emit-p (or (not previous-p) (not (funcall test current-key previous-key)))))
         (setf previous-key current-key previous-p t)
         (values value emit-p))))))

(defun channel-debounce (interval input &key (buffer-size 0) scope executor)
  "Emit the latest INPUT value after INTERVAL seconds pass with no newer
value arriving. INPUT closing immediately flushes a still-pending value
before closing the output. Does not support a channel that deliberately
sends NIL as a real value -- see the source comment on its inner SELECT for
why.

Returns two values: an output channel and a completion promise. Ownership,
cancellation, and executor behavior are the same as CHANNEL-MAP."
  (check-type interval (real 0))
  (check-type input channel)
  (let ((output (make-channel :buffer-size buffer-size)))
    (values
     output
     (%start-channel-stage
      (lambda ()
        (%with-closed-stage-outputs ((list output))
          (let ((pending-value nil)
                (pending-p nil))
            ;; An explicit named block, not the (LOOP ...)'s own implicit
            ;; NIL block: SELECT below macro-inlines its own internal
            ;; probing loop, which establishes ITS OWN implicit NIL block
            ;; textually closer to the clause body than this one -- a bare
            ;; (RETURN) inside a SELECT clause exits SELECT's own loop, not
            ;; this one, leaving PENDING-P still true and this loop looping
            ;; again to redeliver an already-sent PENDING-VALUE into a
            ;; channel nothing is still draining, and hanging forever.
            (block debounce
              (labels ((wait-for-first-value ()
                         (multiple-value-bind (value received-p) (recv input)
                           (unless received-p (return-from debounce))
                           (setf pending-value value pending-p t)))
                       (wait-for-quiet-or-flush ()
                         (select
                           ((recv input) (value)
                            ;; SELECT's RECV clause binds only VALUE, unlike plain
                            ;; RECV's own (VALUES VALUE RECEIVED-P) -- it fires
                            ;; alike for a genuinely received value and for INPUT
                            ;; closed-and-drained (VALUE then NIL), with no
                            ;; RECEIVED-P of its own to tell them apart. A NIL
                            ;; VALUE while INPUT is already closed is therefore
                            ;; taken as "no more values are coming" and flushes
                            ;; PENDING-VALUE -- ambiguous only for a channel that
                            ;; deliberately sends NIL as a real value, which
                            ;; CHANNEL-DEBOUNCE does not support distinguishing.
                            (if (and (null value) (channel-closed-p input))
                                (progn (send output pending-value) (return-from debounce))
                                (setf pending-value value)))
                           (:timeout interval ()
                            (send output pending-value)
                            (setf pending-p nil)))))
                (loop
                  (when scope (check-cancelled scope))
                  (if pending-p (wait-for-quiet-or-flush) (wait-for-first-value))))))))
      :scope scope :executor executor :outputs (list output)))))

(defun channel-flat-map (function input &key (buffer-size 0) scope executor)
  "Apply FUNCTION to each INPUT value and forward every value in its
returned sequence, in order, fully before the next input is received.

Returns two values: an output channel and a completion promise. Ownership,
closure, cancellation, and executor behavior are the same as CHANNEL-MAP."
  (%make-channel-emitting-stage
   input buffer-size scope executor
   (lambda (value emit) (map nil emit (funcall function value)))))

(defun channel-throttle (interval input &key (buffer-size 0) scope executor)
  "Emit the first INPUT value in each INTERVAL-second window immediately;
later values received before the window expires are consumed and discarded.

Returns two values: an output channel and a completion promise. Ownership,
cancellation, and executor behavior are the same as CHANNEL-MAP."
  (check-type interval (real 0))
  (check-type input channel)
  (let ((output (make-channel :buffer-size buffer-size))
        (next-emit-time nil))
    (values
     output
     (%start-channel-stage
      (lambda ()
        (%with-closed-stage-outputs ((list output))
          (loop
            (when scope (check-cancelled scope))
            (multiple-value-bind (value received-p) (recv input)
              (unless received-p (return))
              (let ((now (get-internal-real-time)))
                (when (or (null next-emit-time) (>= now next-emit-time))
                  (send output value)
                  (setf next-emit-time (+ now (round (* interval internal-time-units-per-second))))))))))
      :scope scope :executor executor :outputs (list output)))))

(defun channel-scan (function initial-value input &key (buffer-size 0) scope executor)
  "Accumulate INPUT with FUNCTION (called with the previous accumulator and
the next input value) and emit each successive accumulator value. The
initial value itself is not emitted.

Returns two values: an output channel and a completion promise. Ownership,
closure, cancellation, and executor behavior are the same as CHANNEL-MAP."
  (let ((accumulator initial-value))
    (%make-channel-stage
     input buffer-size scope executor
     (lambda (value)
       (setf accumulator (funcall function accumulator value))
       (values accumulator t)))))

(defmacro %consume-channel ((value-var input scope on-close) &body body)
  "Loop receiving successive values from INPUT into VALUE-VAR, checking
SCOPE's cancellation before each one and running BODY once per value, until
INPUT closes -- at which point the loop returns ON-CLOSE -- or BODY itself
escapes early with (RETURN value). Shared LOOP/RECV/CHECK-CANCELLED skeleton
behind CHANNEL-REDUCE, CHANNEL-COLLECT, CHANNEL-EACH, CHANNEL-SOME,
CHANNEL-EVERY, and CHANNEL-FIND below, which differ only in what they
accumulate along the way and what ON-CLOSE or an early BODY return should be."
  `(loop
     (when ,scope (check-cancelled ,scope))
     (multiple-value-bind (,value-var received-p) (recv ,input)
       (unless received-p (return ,on-close))
       ,@body)))

(defun channel-reduce (function initial-value input &key scope executor)
  "Reduce INPUT with FUNCTION (called with the previous accumulator and the
next input value) and resolve to its final accumulator value.

Returns a completion promise: INITIAL-VALUE for an empty INPUT, or the final
accumulator once INPUT closes. With SCOPE, the reducer is a tracked child and
a reducer failure cancels SCOPE; with EXECUTOR, it runs on that executor.
Synchronous task-start failures are reported through the returned promise."
  (check-type input channel)
  (let ((accumulator initial-value))
    (%start-channel-stage
     (lambda ()
       (%consume-channel (value input scope accumulator)
         (setf accumulator (funcall function accumulator value))))
     :scope scope :executor executor)))

(defun channel-collect (input &key scope executor)
  "Collect INPUT into a promise for a list of its values in input order.

The promise resolves once INPUT closes, or rejects if INPUT, SCOPE, or
EXECUTOR fails."
  (check-type input channel)
  (let (reversed-values)
    (%start-channel-stage
     (lambda ()
       (%consume-channel (value input scope (nreverse reversed-values))
         (push value reversed-values)))
     :scope scope :executor executor)))

(defun channel-each (function input &key scope executor)
  "Consume every value from INPUT with FUNCTION, in input order, and return
a completion promise resolving to NIL once INPUT closes, or rejecting if
FUNCTION, INPUT, SCOPE, or EXECUTOR fails."
  (check-type function function)
  (check-type input channel)
  (%start-channel-stage
   (lambda ()
     (%consume-channel (value input scope nil)
       (funcall function value)))
   :scope scope :executor executor))

(defun channel-some (predicate input &key scope executor)
  "Resolve to the first truthy result of PREDICATE over INPUT, stopping
there and leaving later input values available. Resolves to NIL once INPUT
closes without a match."
  (check-type predicate function)
  (check-type input channel)
  (%start-channel-stage
   (lambda ()
     (%consume-channel (value input scope nil)
       (let ((result (funcall predicate value)))
         (when result (return result)))))
   :scope scope :executor executor))

(defun channel-every (predicate input &key scope executor)
  "Resolve to T once PREDICATE holds for every value received from INPUT --
stopping and resolving to NIL after the first false result, and leaving
later input values available."
  (check-type predicate function)
  (check-type input channel)
  (%start-channel-stage
   (lambda ()
     (%consume-channel (value input scope t)
       (unless (funcall predicate value) (return nil))))
   :scope scope :executor executor))

(defun channel-find (predicate input &key scope executor)
  "Resolve to the first INPUT value for which PREDICATE is truthy, stopping
there and leaving later input values available. Resolves to NIL once INPUT
closes without a match."
  (check-type predicate function)
  (check-type input channel)
  (%start-channel-stage
   (lambda ()
     (%consume-channel (value input scope nil)
       (when (funcall predicate value) (return value))))
   :scope scope :executor executor))
