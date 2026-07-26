;;;; src/select.lisp
;;;;
;;;; Go-style SELECT: wait on several channel operations at once and run
;;;; whichever becomes ready first. Built on TRY-SEND/TRY-RECV (never
;;;; blocking, so no clause can hang the others) plus a private semaphore
;;;; registered as a CHANNEL waiter (src/channel.lisp's %CHANNEL-ADD-WAITER),
;;;; so a SELECT with nothing ready sleeps instead of busy-polling and wakes
;;;; as soon as any one of its channels changes state.
(in-package #:cl-concurrent-kit)

(defmacro select (&body clauses)
  "Wait on multiple channel operations, running the body of whichever becomes
ready first. Each clause is one of:

  ((recv channel-form) (value-var) body...)
  ((send channel-form value-form) () body...)
  (:default () body...)
  (:timeout seconds-form () body...)

:DEFAULT, if present, runs immediately when no other clause is ready.
:TIMEOUT, if present, runs if no other clause becomes ready within
SECONDS-FORM. At most one of the two may appear. If neither appears, SELECT
blocks until some clause is ready. SELECT returns whatever the chosen
clause's body returns."
  (let (default-thunk-form timeout-form runtime-clause-forms)
    (dolist (clause clauses)
      (ecase (if (keywordp (first clause)) (first clause) :operation)
        (:default
         (when default-thunk-form
           (error "SELECT: at most one :DEFAULT clause is allowed"))
         (destructuring-bind (() &body body) (rest clause)
           (setf default-thunk-form `(lambda () ,@body))))
        (:timeout
         (when timeout-form
           (error "SELECT: at most one :TIMEOUT clause is allowed"))
         (destructuring-bind (seconds () &body body) (rest clause)
           (setf timeout-form `(cons ,seconds (lambda () ,@body)))))
        (:operation
         (destructuring-bind ((op &rest op-args) bindings &body body) clause
           (push
            (ecase op
              (recv
               (destructuring-bind (channel-form) op-args
                 (destructuring-bind (&optional value-var) bindings
                   `(list :kind :recv :channel ,channel-form
                          :handler (lambda (,@(when value-var (list value-var)))
                                     ,@body)))))
              (send
               (destructuring-bind (channel-form value-form) op-args
                 `(list :kind :send :channel ,channel-form
                        :value (lambda () ,value-form)
                        :handler (lambda () ,@body)))))
            runtime-clause-forms)))))
    `(%run-select (list ,@(nreverse runtime-clause-forms)) ,default-thunk-form ,timeout-form)))

(defun %shuffled (list)
  "A fresh, randomly permuted copy of LIST (Fisher-Yates), so a SELECT with
several ready clauses does not always favor whichever was written first."
  (let ((vector (coerce list 'vector)))
    (loop for i from (1- (length vector)) downto 1
          do (rotatef (aref vector i) (aref vector (random (1+ i)))))
    (coerce vector 'list)))

(defun %try-clause (clause)
  "Attempt CLAUSE's operation without blocking. Returns a thunk to call for
its result if it succeeded, or NIL if it would have blocked."
  (ecase (getf clause :kind)
    (:recv
     (multiple-value-bind (value received-p) (try-recv (getf clause :channel))
       (when received-p
         (lambda () (funcall (getf clause :handler) value)))))
    (:send
     (when (try-send (getf clause :channel) (funcall (getf clause :value)))
       (getf clause :handler)))))

(defun %run-select (clauses default-thunk timeout)
  "Runtime engine behind SELECT. TIMEOUT is (SECONDS . THUNK) or NIL. At most
one of DEFAULT-THUNK and TIMEOUT is non-NIL; the macro enforces that."
  (let ((waiter (make-semaphore)))
    (unwind-protect
        (let ((deadline (when timeout (%deadline-from-timeout (car timeout)))))
          ;; Registering here, inside the protected form, means a failure
          ;; partway through (or a non-local exit from a clause's own
          ;; channel-form) still reaches the cleanup below, which removes the
          ;; waiter from every clause unconditionally -- including ones it was
          ;; never actually added to, where DELETE is simply a no-op.
          (dolist (clause clauses)
            (%channel-add-waiter (getf clause :channel) waiter))
          (loop
            (dolist (clause (%shuffled clauses))
              (let ((winner (%try-clause clause)))
                (when winner (return-from %run-select (funcall winner)))))
            (cond
              (default-thunk (return-from %run-select (funcall default-thunk)))
              (deadline
               (let ((remaining (/ (- deadline (get-internal-real-time))
                                    (float internal-time-units-per-second 0.0d0))))
                 (if (<= remaining 0)
                     (return-from %run-select (funcall (cdr timeout)))
                     (wait-on-semaphore waiter :timeout remaining))))
              (t (wait-on-semaphore waiter)))))
      (dolist (clause clauses)
        (%channel-remove-waiter (getf clause :channel) waiter)))))
