;;;; src/promise-combinators.lisp
;;;;
;;;; Deriving a new PROMISE from existing ones -- PROMISE-ALL-SETTLED,
;;;; PROMISE-RACE, PROMISE-THEN, PROMISE-CATCH, PROMISE-FINALLY, PROMISE-ALL,
;;;; and PROMISE-ANY -- as opposed to src/promise.lisp's core write-once cell
;;;; (MAKE-PROMISE/DELIVER/DELIVER-ERROR/AWAIT/CANCEL-PROMISE) and its
;;;; thread-spawning convenience, FUTURE. Every combinator above is built
;;;; purely on %OBSERVE-PROMISE's continuation registration: none of them
;;;; spawns a thread, queues work, or polls. PROMISE-TIMEOUT is the one
;;;; exception -- a delayed action needs a thread somewhere, since this
;;;; package has no reactor/timer infrastructure to hand it to instead.
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

(defmacro %unless-decided ((lock decided-place) &body body)
  "Run BODY with LOCK held, but only if DECIDED-PLACE (a place shared by every
observer racing the same promise combinator below) is not yet true; return
NIL without running BODY at all once some other observer has already set it.

BODY is responsible for setting DECIDED-PLACE itself, exactly when this
observer has decided the race outright rather than merely recorded its own
input -- PROMISE-ALL and PROMISE-ANY only set it once a completion count
reaches zero, while PROMISE-RACE and PROMISE-TIMEOUT set it immediately (see
%DECIDE-ONCE for that simpler shape). Doing the recording and the deciding in
one BODY under one lock acquisition, rather than as two separate critical
sections, is what keeps a value written by a losing observer from being
recorded after a winner has already been delivered."
  `(with-lock-held (,lock) (unless ,decided-place ,@body)))

(defmacro %decide-once (lock decided-place)
  "Claim DECIDED-PLACE for the calling observer if no other observer racing
the same promise combinator has claimed it yet, returning T to whichever call
does so first and NIL to every later one. The common case of
%UNLESS-DECIDED where deciding needs no input of its own to record -- merely
being called at all is enough to win."
  `(%unless-decided (,lock ,decided-place) (setf ,decided-place t)))

(defmacro %with-race-cleanup ((lock decided count promises observers) &body body)
  "Establish DECIDED-P, STOP-OBSERVING-OTHERS, and REGISTER-OBSERVER as local
functions for BODY, reaching LOCK, DECIDED, COUNT, PROMISES, and OBSERVERS by
name from the caller's own lexical scope -- the anaphor is deliberate, the
same shape %DEFINE-KIT-CONDITION's CONDITION already establishes for a
:REPORT clause. DECIDED-P reads DECIDED under LOCK. STOP-OBSERVING-OTHERS
(EXCEPT-INDEX) unregisters every observer in OBSERVERS from its own entry in
PROMISES except the one at EXCEPT-INDEX -- the winning input, whose own
observer a caller might still need to unregister separately once DECIDED-P is
true. REGISTER-OBSERVER (INDEX OBSERVER) stores OBSERVER at INDEX, subscribes
it to PROMISES's own entry there, and immediately unsubscribes it again if the
race was already decided by the time %OBSERVE-PROMISE returned -- closing the
window between an input settling synchronously inside that call and this
caller finding out the race is over. Shared by PROMISE-ALL and PROMISE-ANY
below, which race COUNT promises identically and differ only in what a
fulfilled or failed input means for each."
  `(flet ((decided-p () (with-lock-held (,lock) ,decided))
          (stop-observing-others (except-index)
            (dotimes (i ,count)
              (unless (= i except-index)
                (%unobserve-promise (aref ,promises i) (aref ,observers i))))))
     (flet ((register-observer (index observer)
              (setf (aref ,observers index) observer)
              (%observe-promise (aref ,promises index) observer)
              (when (decided-p)
                (%unobserve-promise (aref ,promises index) observer))))
       ,@body)))

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
           (when (%decide-once lock decided)
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

(defun promise-all (promises)
  "Return a PROMISE fulfilled with a list of every promise in PROMISES's
values, in input order, once every one has fulfilled. Fails as soon as any
input fails, with that input's own condition -- and stops observing every
other still-pending input at that point instead of continuing to retain
them. PROMISES may be any sequence; an empty one fulfills immediately with
NIL."
  (let* ((promises (coerce promises 'vector))
         (count (length promises))
         (result (make-promise)))
    (dotimes (i count) (check-type (aref promises i) promise))
    (if (zerop count)
        (deliver result nil)
        (let ((lock (make-lock :name "cl-concurrent-kit promise-all"))
              (values (make-array count))
              (remaining count)
              (decided nil)
              (observers (make-array count :initial-element nil)))
          (%with-race-cleanup (lock decided count promises observers)
            (dotimes (index count)
              (let ((index index))
                (register-observer
                 index
                 (lambda (state outcome)
                   (ecase state
                     (:fulfilled
                      (when (%unless-decided (lock decided)
                              (setf (aref values index) outcome)
                              (let ((complete-p (zerop (decf remaining))))
                                (when complete-p (setf decided t))
                                complete-p))
                        (%deliver-if-pending result (coerce values 'list))))
                     (:failed
                      (when (%decide-once lock decided)
                        (stop-observing-others index)
                        (%deliver-error-if-pending result outcome)))))))))))
    result))

(defun promise-any (promises)
  "Return a PROMISE fulfilled by whichever promise in PROMISES fulfills
first, discarding every other still-pending input's observer once a winner
is decided. If every input fails, fails with PROMISE-ALL-FAILED collecting
every failure in input order. Signals PROMISE-EMPTY-INPUT immediately -- like
PROMISE-RACE -- if PROMISES is empty."
  (let ((promises (coerce promises 'list)))
    (dolist (promise promises) (check-type promise promise))
    (when (null promises)
      (error 'promise-empty-input :operation :promise-any))
    (let* ((promises (coerce promises 'vector))
           (count (length promises))
           (result (make-promise))
           (lock (make-lock :name "cl-concurrent-kit promise-any"))
           (failures (make-array count))
           (remaining count)
           (decided nil)
           (observers (make-array count :initial-element nil)))
      (%with-race-cleanup (lock decided count promises observers)
        (dotimes (index count)
          (let ((index index))
            (register-observer
             index
             (lambda (state outcome)
               (ecase state
                 (:fulfilled
                  (when (%decide-once lock decided)
                    (stop-observing-others index)
                    (%deliver-if-pending result outcome)))
                 (:failed
                  (let ((causes (%unless-decided (lock decided)
                                  (setf (aref failures index) outcome)
                                  (when (zerop (decf remaining))
                                    (setf decided t)
                                    (coerce failures 'list)))))
                    (when causes
                      (%deliver-error-if-pending
                       result
                       (make-condition 'promise-all-failed :causes causes)))))))))))
      result)))

(defun promise-timeout (promise timeout)
  "Return a PROMISE that mirrors PROMISE unless TIMEOUT (seconds) elapses
first, in which case it fails with OPERATION-TIMED-OUT and stops observing
PROMISE. Spawns one thread to run the timer; whichever side loses the race --
PROMISE settling first, or the timer firing first -- stops the other
promptly instead of leaking an observer or a sleeping thread until it
happens to finish on its own."
  (check-type promise promise)
  (check-type timeout (real 0 *))
  (let ((result (make-promise))
        (lock (make-lock :name "cl-concurrent-kit promise-timeout"))
        (stop (make-semaphore :name "cl-concurrent-kit promise-timeout stop"))
        (decided nil)
        (observer nil))
    (flet ((on-promise-settled (state outcome)
             (when (%decide-once lock decided)
               (signal-semaphore stop)
               (ecase state
                 (:fulfilled (%deliver-if-pending result outcome))
                 (:failed (%deliver-error-if-pending result outcome)))))
           (run-timer ()
             (unless (wait-on-semaphore stop :timeout timeout)
               (when (%decide-once lock decided)
                 (%unobserve-promise promise observer)
                 (%deliver-error-if-pending
                  result
                  (make-condition 'operation-timed-out :operation :promise-timeout :timeout timeout))))))
      (setf observer (function on-promise-settled))
      (%observe-promise promise observer)
      (make-thread (function run-timer) :name "cl-concurrent-kit promise-timeout timer"))
    result))
