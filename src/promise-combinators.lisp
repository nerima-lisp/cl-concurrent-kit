;;;; src/promise-combinators.lisp
;;;;
;;;; Deriving a new PROMISE from existing ones -- PROMISE-ALL-SETTLED,
;;;; PROMISE-RACE, and PROMISE-THEN -- as opposed to src/promise.lisp's core
;;;; write-once cell (MAKE-PROMISE/DELIVER/DELIVER-ERROR/AWAIT) and its
;;;; thread-spawning convenience, FUTURE. Every combinator here is built
;;;; purely on %OBSERVE-PROMISE's continuation registration: none of them
;;;; spawns a thread, queues work, or polls.
(in-package #:cl-concurrent-kit)

(defstruct (promise-settlement
    (:constructor %make-promise-settlement (state value condition))) "The outcome of one input to PROMISE-ALL-SETTLED.

STATE is either :FULFILLED or :FAILED.  VALUE is meaningful for fulfilled
settlements, and CONDITION is meaningful for failed settlements."
  (state :fulfilled :read-only t)
  (value nil :read-only t)
  (condition nil :read-only t))

(defun promise-all-settled (promises)
  "Return a PROMISE fulfilled after every PROMISE in PROMISES settles.

Its value is a list of PROMISE-SETTLEMENT records in the same order as
PROMISES.  Failed inputs produce :FAILED records instead of failing the
aggregate promise."
  (let* ((promises (coerce promises 'list))
         (count (length promises))
         (aggregate (make-promise)))
    (dolist (promise promises)
      (check-type promise promise))
    (if (zerop count) (deliver aggregate nil)
      (let ((lock (make-lock :name "cl-concurrent-kit promise all settled"))
            (remaining count)
            (settlements (make-array count)))
        (loop for promise in promises
              for index from 0
              do (let ((index index))
                   ;; LOOP's FOR mutates one binding of INDEX in place rather
                   ;; than creating a fresh one per iteration, so the closure
                   ;; below needs its own copy -- otherwise every observer
                   ;; would write to whatever INDEX the loop had reached by
                   ;; the time a promise actually settled, not the slot it
                   ;; was registered for.
                   (%observe-promise
                    promise
                    (lambda (state outcome)
                      (let (complete)
                        (with-lock-held
                          (lock)
                          (setf (aref settlements index) (ecase state
                              (:fulfilled (%make-promise-settlement :fulfilled outcome nil))
                              (:failed (%make-promise-settlement :failed nil outcome))))
                          (setf complete (zerop (decf remaining))))
                        (when complete
                          (deliver aggregate (coerce settlements 'list))))))))))
    aggregate))

(defun promise-race (promises)
  "Return a PROMISE that settles the same way -- fulfilled or failed -- as
whichever PROMISE in PROMISES settles first. PROMISES must be non-empty.

Like PROMISE-THEN, this is pure continuation-passing composition on
%OBSERVE-PROMISE: no thread is spawned and no promise is polled. Every
settlement among PROMISES after the first winner is observed and discarded
under a lock, rather than raising PROMISE-ALREADY-FULFILLED against the
result."
  (let ((promises (coerce promises 'list)))
    (dolist (promise promises)
      (check-type promise promise))
    (when (null promises)
      (error "PROMISE-RACE requires at least one promise."))
    (let ((winner (make-promise))
          (lock (make-lock :name "cl-concurrent-kit promise race"))
          (decided nil))
      (dolist (promise promises)
        (%observe-promise
         promise
         (lambda (state outcome)
           (when (with-lock-held
                     (lock)
                   (unless decided (setf decided t)))
             (ecase state
               (:fulfilled (deliver winner outcome))
               (:failed (deliver-error winner outcome)))))))
      winner)))

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
