;;;; src/promise-combinators.lisp
;;;;
;;;; Promise transformations and all-settled aggregation. These operators
;;;; observe every input through completion; racing operators live in
;;;; promise-racing.lisp. They register continuations and do not spawn threads
;;;; or poll. promise-racing.lisp uses %CHECK-PROMISES from this file.
(in-package #:cl-concurrent-kit)

(defstruct (promise-settlement
    (:constructor %make-promise-settlement (state value condition))) "The outcome of one input to PROMISE-ALL-SETTLED.

STATE is either :FULFILLED or :FAILED.  VALUE is meaningful for fulfilled
settlements, and CONDITION is meaningful for failed settlements."
  (state :fulfilled :read-only t)
  (value nil :read-only t)
  (condition nil :read-only t))

(defun %promise-settlement-for (state outcome)
  "The PROMISE-SETTLEMENT recording one input's outcome for
PROMISE-ALL-SETTLED, given the STATE and OUTCOME %OBSERVE-PROMISE calls its
continuation with."
  (ecase state
    (:fulfilled (%make-promise-settlement :fulfilled outcome nil))
    (:failed (%make-promise-settlement :failed nil outcome))))

(defun %check-promises (promises)
  "Signal a TYPE-ERROR unless every element of the sequence PROMISES is a
PROMISE. Returns PROMISES unchanged, so a caller can wrap it directly around
a COERCE."
  (map nil (lambda (promise) (check-type promise promise)) promises)
  promises)

(defun promise-all-settled (promises)
  "Return a PROMISE fulfilled after every PROMISE in PROMISES settles.

Its value is a list of PROMISE-SETTLEMENT records in the same order as
PROMISES.  Failed inputs produce :FAILED records instead of failing the
aggregate promise."
  (let* ((promises (%check-promises (coerce promises 'list)))
         (count (length promises))
         (aggregate (make-promise)))
    (if (zerop count)
        (deliver aggregate nil)
        (let ((lock (make-lock :name "cl-concurrent-kit promise all settled"))
              (remaining count)
              (settlements (make-array count)))
          (flet ((record-settlement (index promise)
                   (%observe-promise
                    promise
                    (lambda (state outcome)
                      (let (complete)
                        (with-lock-held (lock)
                          (setf (aref settlements index) (%promise-settlement-for state outcome))
                          (setf complete (zerop (decf remaining))))
                        (when complete
                          (deliver aggregate (coerce settlements 'list))))))))
            (loop for promise in promises
                  for index from 0
                  do (let ((index index))
                       ;; LOOP's FOR mutates one binding of INDEX in place rather
                       ;; than creating a fresh one per iteration, so the closure
                       ;; below needs its own copy -- otherwise every observer
                       ;; would write to whatever INDEX the loop had reached by
                       ;; the time a promise actually settled, not the slot it
                       ;; was registered for.
                       (record-settlement index promise))))))
    aggregate))

(defun promise-then (promise on-fulfilled &optional on-rejected)
  "Register ON-FULFILLED and ON-REJECTED as PROMISE's continuations and
return a new PROMISE for whichever one runs -- explicit continuation-passing
style built directly on %OBSERVE-PROMISE's own callback: PROMISE-THEN never
blocks, never spawns a thread, and settles its result promise from whatever
thread settles PROMISE (immediately, inline, if PROMISE is already settled).

Called with PROMISE's value, ON-FULFILLED's return value fulfills the result;
an error it signals fails it instead. ON-REJECTED, if supplied, is called
with the condition DELIVER-ERROR settled PROMISE with and its return value
fulfills the result; if omitted, a failed PROMISE simply propagates its
condition to the result unchanged."
  (let ((next (make-promise)))
    (%observe-promise
     promise
     (lambda (state outcome)
       (handler-case
           (deliver next
                    (ecase state
                      (:fulfilled (funcall on-fulfilled outcome))
                      (:failed (if on-rejected (funcall on-rejected outcome) (error outcome)))))
         (error (condition) (deliver-error next condition)))))
    next))

(defun promise-catch (promise on-rejected)
  "Return a PROMISE that mirrors PROMISE's own value when it fulfills, or is
settled by calling ON-REJECTED with the condition PROMISE failed with when it
fails. Like PROMISE-THEN, pure continuation-passing composition on
%OBSERVE-PROMISE: no thread is spawned, and PROMISE-CATCH settles its result
promise from whatever thread settles PROMISE (immediately, inline, if PROMISE
is already settled)."
  (let ((next (make-promise)))
    (%observe-promise
     promise
     (lambda (state outcome)
       (ecase state
         (:fulfilled (deliver next outcome))
         (:failed
          (handler-case (deliver next (funcall on-rejected outcome))
            (error (condition) (deliver-error next condition)))))))
    next))

(defun promise-finally (promise function)
  "Return a PROMISE that mirrors PROMISE's own settlement once FUNCTION --
called with no arguments, purely for its side effect -- has run after PROMISE
settles, regardless of outcome. If FUNCTION itself signals, that condition
settles the result instead of PROMISE's own outcome. Pure
continuation-passing composition on %OBSERVE-PROMISE, like PROMISE-THEN: no
thread is spawned."
  (let ((next (make-promise)))
    (%observe-promise
     promise
     (lambda (state outcome)
       (handler-case
           (progn
             (funcall function)
             (ecase state
               (:fulfilled (deliver next outcome))
               (:failed (deliver-error next outcome))))
         (error (condition) (deliver-error next condition)))))
    next))
