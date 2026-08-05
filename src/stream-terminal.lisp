;;;; src/stream-terminal.lisp
;;;;
;;;; Terminal stream stages: the operators that consume a channel all the way
;;;; down to a single PROMISE result, rather than producing another channel to
;;;; read from. Every stage in SRC/STREAM.LISP proper returns two values -- an
;;;; output channel and a completion promise -- and is meant to be composed
;;;; into a longer pipeline; every stage here returns one promise and ends the
;;;; pipeline, because there is nothing downstream left to hand a channel to.
;;;; They own no output channel and so pass no :OUTPUTS to %WITH-CHANNEL-STAGE.
;;;;
;;;; The shared :SCOPE/:EXECUTOR ownership and cancellation contract is
;;;; SRC/STREAM.LISP's -- see its header comment. These stages reuse that
;;;; file's %WITH-CHANNEL-STAGE, so SRC/STREAM.LISP must be loaded first.
(in-package #:cl-concurrent-kit)

(defun channel-reduce (function initial-value input &key scope executor)
  "Reduce INPUT with FUNCTION (called with the previous accumulator and the
next input value) and resolve to its final accumulator value.

Returns a completion promise: INITIAL-VALUE for an empty INPUT, or the final
accumulator once INPUT closes. With SCOPE, the reducer is a tracked child and
a reducer failure cancels SCOPE; with EXECUTOR, it runs on that executor.
Synchronous task-start failures are reported through the returned promise."
  (check-type input channel)
  (let ((accumulator initial-value))
    (%with-channel-stage (:scope scope :executor executor)
      (%consume-channel (value input scope accumulator)
        (setf accumulator (funcall function accumulator value))))))

(defun channel-collect (input &key scope executor)
  "Collect INPUT into a promise for a list of its values in input order.

The promise resolves once INPUT closes, or rejects if INPUT, SCOPE, or
EXECUTOR fails."
  (check-type input channel)
  (let (reversed-values)
    (%with-channel-stage (:scope scope :executor executor)
      (%consume-channel (value input scope (nreverse reversed-values))
        (push value reversed-values)))))

(defun channel-each (function input &key scope executor)
  "Consume every value from INPUT with FUNCTION, in input order, and return
a completion promise resolving to NIL once INPUT closes, or rejecting if
FUNCTION, INPUT, SCOPE, or EXECUTOR fails."
  (check-type function function)
  (check-type input channel)
  (%with-channel-stage (:scope scope :executor executor)
    (%consume-channel (value input scope nil)
      (funcall function value))))

(defun channel-some (predicate input &key scope executor)
  "Resolve to the first truthy result of PREDICATE over INPUT, stopping
there and leaving later input values available. Resolves to NIL once INPUT
closes without a match."
  (check-type predicate function)
  (check-type input channel)
  (%with-channel-stage (:scope scope :executor executor)
    (%consume-channel (value input scope nil)
      (let ((result (funcall predicate value)))
        (when result (return result))))))

(defun channel-every (predicate input &key scope executor)
  "Resolve to T once PREDICATE holds for every value received from INPUT --
stopping and resolving to NIL after the first false result, and leaving
later input values available."
  (check-type predicate function)
  (check-type input channel)
  (%with-channel-stage (:scope scope :executor executor)
    (%consume-channel (value input scope t)
      (unless (funcall predicate value) (return nil)))))

(defun channel-find (predicate input &key scope executor)
  "Resolve to the first INPUT value for which PREDICATE is truthy, stopping
there and leaving later input values available. Resolves to NIL once INPUT
closes without a match."
  (check-type predicate function)
  (check-type input channel)
  (%with-channel-stage (:scope scope :executor executor)
    (%consume-channel (value input scope nil)
      (when (funcall predicate value) (return value)))))
