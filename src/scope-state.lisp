;;;; src/scope-state.lisp
;;;;
;;;; TASK-SCOPE's own bookkeeping: the struct, its children, its
;;;; closing/cancellation flags, and the conditions its failed children
;;;; signaled. SPAWN (src/scope-execution.lisp) and WITH-TASK-SCOPE
;;;; (src/scope.lisp) are built entirely on the functions here; splitting the
;;;; three apart is what lets scope.lisp read as just "the public macro" and
;;;; scope-execution.lisp as just "dispatch a child" without this underneath
;;;; either of them.
(in-package #:cl-concurrent-kit)

(defstruct (task-scope (:constructor %make-task-scope ()))
  (lock (make-lock :name "cl-concurrent-kit scope") :read-only t)
  ;; Broadcast whenever a child is removed, so %SCOPE-AWAIT-CHILDREN can wait
  ;; on one predicate (zero children left) instead of one promise per child.
  (condition-variable (make-condition-variable :name "cl-concurrent-kit scope")
                       :read-only t)
  ;; Active child records, keyed by the child object itself. Completed
  ;; children remove themselves so their cancellation closures are not retained.
  (children (make-hash-table :test (function eq)) :read-only t)
  ;; Thunks registered by non-child waiters (e.g. AWAIT-LATCH/AWAIT-BARRIER
  ;; via their optional :SCOPE argument) that want to be called once when
  ;; SCOPE is cancelled, keyed by the thunk itself so the same closure can be
  ;; removed again in an UNWIND-PROTECT once its own wait ends. Unlike a
  ;; child, a waker is not "spawned work" -- it does not block
  ;; %SCOPE-AWAIT-CHILDREN and is never rejected for arriving after SCOPE
  ;; started closing, only after it is fully CANCELLED-P.
  (wakers (make-hash-table :test (function eq)) :read-only t)
  ;; True from the moment WITH-TASK-SCOPE's body has returned or signalled,
  ;; even before every child already running has been cancelled and awaited.
  ;; %SCOPE-ADD-CHILD checks this -- not just CANCELLED-P -- so a child that
  ;; tries to SPAWN itself right as the body exits is rejected instead of
  ;; racing %SCOPE-AWAIT-CHILDREN's "zero children left" snapshot.
  (closing-p nil)
  (cancelled-p nil)
  ;; Conditions signaled by failed children, oldest first (reversed on read).
  (failures nil))

(defstruct (%scope-child (:constructor %make-scope-child ()))
  (cancel nil))

(defmacro %with-scope-lock ((scope) &body body)
  "Hold SCOPE's own lock for the dynamic extent of BODY."
  `(with-lock-held ((task-scope-lock ,scope)) ,@body))

(defun check-cancelled (scope)
  "Signal TASK-CANCELLED if SCOPE has been cancelled -- because a sibling
task failed, because WITH-TASK-SCOPE's body exited abnormally, or because
WITH-TASK-SCOPE has already returned. Call this periodically from within
long-running SPAWNed work, at points where stopping early is safe."
  (when (%with-scope-lock (scope) (task-scope-cancelled-p scope))
    (error 'task-cancelled :scope scope)))

(defun %scope-close (scope)
  "Mark SCOPE as closing: no further child may be SPAWNed onto it, even
though it may not be fully CANCELLED-P yet and children already running may
still be awaited normally. Called once, right as WITH-TASK-SCOPE's body
returns or signals, before it starts waiting for those children."
  (%with-scope-lock (scope)
    (setf (task-scope-closing-p scope) t)))

(defun %scope-cancel (scope)
  "Mark SCOPE cancelled and request cancellation of its active children and
registered wakers."
  (let ((cancellers nil)
        (wakers nil))
    (%with-scope-lock (scope)
      (unless (task-scope-cancelled-p scope)
        (setf (task-scope-cancelled-p scope) t
              cancellers
              (loop for child being the hash-keys of (task-scope-children scope)
                    for cancel = (%scope-child-cancel child)
                    when cancel collect cancel)
              wakers
              (loop for waker being the hash-keys of (task-scope-wakers scope)
                    collect waker))))
    (dolist (cancel cancellers)
      (funcall cancel))
    (dolist (waker wakers)
      (funcall waker))))

(defun %scope-add-waker (scope waker)
  "Register WAKER (a thunk) to be called once SCOPE is cancelled. If SCOPE is
already cancelled, WAKER runs immediately instead of being registered."
  (let ((cancel-now nil))
    (%with-scope-lock (scope)
      (if (task-scope-cancelled-p scope)
          (setf cancel-now t)
          (setf (gethash waker (task-scope-wakers scope)) t)))
    (when cancel-now
      (funcall waker))))

(defun %scope-remove-waker (scope waker)
  (%with-scope-lock (scope)
    (remhash waker (task-scope-wakers scope))))

(defun %scope-record-failure (scope condition)
  (%with-scope-lock (scope)
    (push condition (task-scope-failures scope))))

(defun %scope-add-child (scope child)
  "Register CHILD and return true, or reject it (returning NIL) once SCOPE
has started closing. If SCOPE is already cancelled but not yet closing,
CHILD is still registered, and its cancellation closure -- once
%SCOPE-SET-CHILD-CANCEL later supplies one -- runs immediately."
  (let ((added nil)
        (cancel nil))
    (%with-scope-lock (scope)
      (unless (task-scope-closing-p scope)
        (setf (gethash child (task-scope-children scope)) t
              added t)
        (when (task-scope-cancelled-p scope)
          (setf cancel (%scope-child-cancel child)))))
    (when cancel
      (funcall cancel))
    added))

(defun %scope-remove-child (scope child)
  (%with-scope-lock (scope)
    (when (remhash child (task-scope-children scope))
      (condition-broadcast (task-scope-condition-variable scope)))))

(defun %scope-set-child-cancel (scope child cancel)
  (let ((cancel-now nil))
    (%with-scope-lock (scope)
      (setf (%scope-child-cancel child) cancel)
      (when (and (gethash child (task-scope-children scope))
                 (task-scope-cancelled-p scope))
        (setf cancel-now cancel)))
    (when cancel-now
      (funcall cancel-now))))

(defun %scope-child-settled (scope child state outcome)
  "Record a child's outcome once its public promise has been settled, unless
it failed only because SCOPE cancelled it -- a sibling's failure (or SCOPE's
own cancellation) already accounts for that -- then remove it from SCOPE."
  (unless (or (eq state :fulfilled)
              (and (typep outcome 'task-cancelled)
                   (%with-scope-lock (scope) (task-scope-cancelled-p scope))))
    (%scope-record-failure scope outcome)
    (%scope-cancel scope))
  (%scope-remove-child scope child))

(defun %scope-await-children (scope &key timeout)
  "Block until every child SPAWNed on SCOPE has finished, or signal
OPERATION-TIMED-OUT after TIMEOUT (a CL-DATE-KIT:DURATION) elapses --
WITH-TASK-SCOPE's own :TIMEOUT. On a timeout, SCOPE's own cancellation (its
caller's job, not this function's) is what stops the children this stopped
waiting for."
  (let ((timeout (and timeout (cl-date-kit:duration-to-seconds timeout))))
    (%with-scope-lock (scope)
      (%with-deadline-wait (done (task-scope-condition-variable scope) (task-scope-lock scope)
                            (%deadline-from-timeout timeout) timeout :with-task-scope)
          (zerop (hash-table-count (task-scope-children scope)))
        done))))

(defun %scope-await-children-or-cancel (scope timeout)
  "%SCOPE-AWAIT-CHILDREN, taking over the caller's job its own docstring
describes: on OPERATION-TIMED-OUT, cancel SCOPE's still-running children
before re-signalling, rather than leaving that to whoever called this."
  (handler-case
      (%scope-await-children scope :timeout timeout)
    (operation-timed-out (condition)
      (%scope-cancel scope)
      (error condition))))

(defun %scope-signal-failures (scope)
  (let ((failures (%with-scope-lock (scope) (reverse (task-scope-failures scope)))))
    (when failures
      (error 'scope-error :causes failures))))
