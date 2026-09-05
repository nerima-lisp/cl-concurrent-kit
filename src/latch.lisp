;;;; src/latch.lisp
;;;;
;;;; COUNTDOWN-LATCH and BARRIER provide fixed-party rendezvous. Both accept
;;;; an optional TASK-SCOPE and wake waiters when that scope is cancelled.
(in-package #:cl-concurrent-kit)

;;; Countdown latches

(defstruct (countdown-latch (:constructor %make-countdown-latch (count)))
  (lock (make-lock :name "cl-concurrent-kit countdown latch") :read-only t)
  (condition-variable (make-condition-variable :name "cl-concurrent-kit countdown latch")
                       :read-only t)
  (count 0 :type (integer 0 *)))

(defun make-countdown-latch (count)
  "Create a one-shot latch that opens once COUNT-DOWN has run COUNT times (or
immediately, if COUNT is zero). AWAIT-LATCH blocks until it opens."
  (check-type count (integer 0 *))
  (%make-countdown-latch count))

(defun count-down (latch &optional (decrement 1))
  "Reduce LATCH's count by DECREMENT and return the count that remains.
Signals LATCH-COUNT-UNDERFLOW if DECREMENT exceeds the count. Once the count
reaches zero, every current and future AWAIT-LATCH call returns immediately."
  (check-type decrement (integer 0 *))
  (with-lock-held
      ((countdown-latch-lock latch))
    (let ((count (countdown-latch-count latch)))
      (when (> decrement count)
        (error 'latch-count-underflow :latch latch :count count :decrement decrement))
      (decf (countdown-latch-count latch) decrement)
      (when (zerop (countdown-latch-count latch))
        (condition-broadcast (countdown-latch-condition-variable latch)))
      (countdown-latch-count latch))))

(defun %countdown-latch-waker (latch)
  (lambda ()
    (with-lock-held
        ((countdown-latch-lock latch))
      (condition-broadcast (countdown-latch-condition-variable latch)))))

(defun await-latch (latch &key timeout scope)
  "Block until LATCH's count reaches zero, then return T. With TIMEOUT
(a CL-DATE-KIT:DURATION), signals OPERATION-TIMED-OUT if it does not open in
time. With SCOPE, also unblocks and signals TASK-CANCELLED if SCOPE is
cancelled first."
  (let ((timeout (and timeout (cl-date-kit:duration-to-seconds timeout))))
    (let ((waker (and scope (%countdown-latch-waker latch))))
      (when waker
        (%scope-add-waker scope waker))
      (unwind-protect
          (with-lock-held
              ((countdown-latch-lock latch))
            (%with-deadline-wait (result (countdown-latch-condition-variable latch)
                                  (countdown-latch-lock latch)
                                  (%deadline-from-timeout timeout) timeout :await-latch)
                (progn
                  (when scope (check-cancelled scope))
                  (zerop (countdown-latch-count latch)))
              result))
        (when waker
          (%scope-remove-waker scope waker))))))

;;; Cyclic barriers

(defstruct (barrier (:constructor %make-barrier (parties)) (:conc-name %barrier-))
  (parties 1 :type (integer 1 *) :read-only t)
  (lock (make-lock :name "cl-concurrent-kit barrier") :read-only t)
  (condition-variable (make-condition-variable :name "cl-concurrent-kit barrier")
                       :read-only t)
  (waiting 0 :type (integer 0 *))
  (generation 0 :type integer)
  (broken-p nil)
  ;; Preserves the failure result for waiters from a generation RESET-BARRIER
  ;; has already replaced.
  (last-broken-generation nil :type (or null integer)))

(defun make-barrier (parties)
  "Create a reusable barrier that releases all PARTIES callers once every one
of them has called AWAIT-BARRIER."
  (check-type parties (integer 1 *))
  (%make-barrier parties))

(defun barrier-parties (barrier)
  "The fixed number of parties BARRIER requires per generation."
  (%barrier-parties barrier))

(defun barrier-number-waiting (barrier)
  "A snapshot of how many parties have already arrived in BARRIER's current
generation."
  (with-lock-held ((%barrier-lock barrier)) (%barrier-waiting barrier)))

(defun barrier-broken-p (barrier)
  "True once BARRIER rejects arrivals -- from a timeout, a cancelled SCOPE,
or RESET-BARRIER -- until RESET-BARRIER is called."
  (with-lock-held ((%barrier-lock barrier)) (%barrier-broken-p barrier)))

(defun %break-barrier (barrier)
  "Break BARRIER's current generation. Its lock must already be held."
  (unless (%barrier-broken-p barrier)
    (setf (%barrier-last-broken-generation barrier) (%barrier-generation barrier)
          (%barrier-broken-p barrier) t
          (%barrier-waiting barrier) 0)
    (incf (%barrier-generation barrier))
    (condition-broadcast (%barrier-condition-variable barrier))))

(defun %barrier-waker (barrier)
  (lambda ()
    (with-lock-held
        ((%barrier-lock barrier))
      (%break-barrier barrier))))

(defun await-barrier (barrier &key timeout scope)
  "Arrive at BARRIER and block until every party in its current generation
has also arrived. Returns 0 to whichever caller arrives last, and a positive
arrival index (counting from 1) to every other caller.

A TIMEOUT (a CL-DATE-KIT:DURATION) or a cancelled SCOPE breaks the current
generation for every party and signals OPERATION-TIMED-OUT or TASK-CANCELLED
respectively; every other party still waiting in that generation instead
signals BARRIER-BROKEN. Call RESET-BARRIER before BARRIER can be used again."
  (let ((timeout (and timeout (cl-date-kit:duration-to-seconds timeout))))
    (let ((waker (and scope (%barrier-waker barrier))))
      (when waker
        (%scope-add-waker scope waker))
      (unwind-protect
          (handler-case
              (with-lock-held
                  ((%barrier-lock barrier))
                (when (%barrier-broken-p barrier)
                  (error 'barrier-broken :barrier barrier))
                (let ((generation (%barrier-generation barrier))
                      (arrival-index (%barrier-waiting barrier)))
                  (incf (%barrier-waiting barrier))
                  (flet ((release-as-last-party ()
                           (setf (%barrier-waiting barrier) 0)
                           (incf (%barrier-generation barrier))
                           (condition-broadcast (%barrier-condition-variable barrier))
                           0)
                         (wait-for-release ()
                           (%with-deadline-wait (result (%barrier-condition-variable barrier)
                                                 (%barrier-lock barrier)
                                                 (%deadline-from-timeout timeout) timeout :await-barrier)
                               (progn
                                 (when scope (check-cancelled scope))
                                 (cond
                                   ((eql generation (%barrier-last-broken-generation barrier)) :broken)
                                   ((/= generation (%barrier-generation barrier)) :advanced)))
                             (ecase result
                               (:broken (error 'barrier-broken :barrier barrier))
                               (:advanced (1+ arrival-index))))))
                    (if (= (%barrier-waiting barrier) (%barrier-parties barrier))
                        (release-as-last-party)
                        (wait-for-release)))))
            ((or task-cancelled operation-timed-out) (condition)
              (with-lock-held ((%barrier-lock barrier)) (%break-barrier barrier))
              (error condition)))
        (when waker
          (%scope-remove-waker scope waker))))))

(defun reset-barrier (barrier)
  "Abandon BARRIER's current generation -- every party still waiting in it
signals BARRIER-BROKEN -- and permit a fresh generation to begin. Returns
BARRIER."
  (with-lock-held
      ((%barrier-lock barrier))
    (%break-barrier barrier)
    (setf (%barrier-broken-p barrier) nil)
    (incf (%barrier-generation barrier))
    (condition-broadcast (%barrier-condition-variable barrier)))
  barrier)
