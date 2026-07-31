;;;; src/select.lisp
;;;;
;;;; Go-style SELECT: wait on several channel operations at once and run
;;;; whichever becomes ready first. Built on TRY-SEND/TRY-RECV (never
;;;; blocking, so no clause can hang the others) plus a private semaphore
;;;; registered as a CHANNEL waiter (src/channel.lisp's %CHANNEL-ADD-WAITER),
;;;; so a SELECT with nothing ready sleeps instead of busy-polling and wakes
;;;; as soon as any one of its channels changes state.
(in-package #:cl-concurrent-kit)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (let (#+sbcl (sb-ext:*evaluator-mode* :interpret))
    (eval '(defun %expand-select (clauses)
  "Wait on channel operations and execute the first ready clause directly."
  (let ((operations nil)
        (default-body nil)
        (default-seen-p nil)
        (timeout nil))
    (dolist (clause clauses)
      (ecase (if (keywordp (first clause)) (first clause) :operation)
        (:default
         (when default-seen-p
           (error "SELECT: at most one :DEFAULT clause is allowed"))
         (destructuring-bind (() &body body) (rest clause)
           (setf default-body body
                 default-seen-p t)))
        (:timeout
         (when timeout
           (error "SELECT: at most one :TIMEOUT clause is allowed"))
         (destructuring-bind (seconds () &body body) (rest clause)
           (setf timeout (cons seconds body))))
        (:operation
         (destructuring-bind ((operator &rest arguments) bindings &body body) clause
           (push
            (ecase operator
              (recv
               (destructuring-bind (channel-form) arguments
                 (destructuring-bind (&optional value-variable) bindings
                   (list :recv channel-form value-variable body))))
              (send
               (destructuring-bind (channel-form value-form) arguments
                 (list :send channel-form value-form body))))
            operations)))))
    (unless operations
      (error "SELECT: at least one channel operation is required"))
    (when (and default-seen-p timeout)
      (error "SELECT: :DEFAULT and :TIMEOUT are mutually exclusive"))
    (let* ((ordered (nreverse operations))
           (waiter (gensym "WAITER"))
           (deadline (gensym "DEADLINE"))
           (block (gensym "SELECT"))
           (bindings
            (loop for operation in ordered
                  collect (let ((channel (gensym "CHANNEL")))
                            (ecase (first operation)
                              (:recv (list operation channel nil))
                              (:send (list operation channel (gensym "VALUE")))))))
           (binding-forms
            (loop for binding in bindings
                  for operation = (first binding)
                  for channel = (second binding)
                  for value = (third binding)
                  append (if value
                             (list (list channel (second operation))
                                   (list value (third operation)))
                             (list (list channel (second operation))))))
           (registration-forms
            (loop for binding in bindings
                  for operation = (first binding)
                  for channel = (second binding)
                  collect `(%channel-add-waiter
                             ,channel
                             ,waiter
                             ,(if (eq (first operation) :recv)
                                  +channel-notify-recv+
                                  +channel-notify-send+))))
           (removal-forms
            (loop for binding in bindings
                  collect `(%channel-remove-waiter ,(second binding) ,waiter)))
           (probe-forms
            (loop for binding in bindings
                  for operation = (first binding)
                  for channel = (second binding)
                  for value = (third binding)
                  collect
                  (ecase (first operation)
                    (:recv
                     (let ((variable (third operation))
                           (body (fourth operation))
                           (received (gensym "RECEIVED"))
                           (closed (gensym "CLOSED"))
                           (result (gensym "RESULT")))
                       `(multiple-value-bind (,result ,received ,closed)
                             (try-recv ,channel)
                           (when (or ,received ,closed)
                             (return-from ,block
                               ,(if variable
                                    `(let ((,variable ,result)) ,@body)
                                    `(locally ,@body)))))))
                    (:send
                     (let ((body (fourth operation)))
                       `(when (try-send ,channel ,value)
                          (return-from ,block (locally ,@body)))))))))
      `(let* (,@binding-forms
               (,waiter (make-semaphore))
               (,deadline ,(when timeout `(%deadline-from-timeout ,(car timeout)))))
         (block ,block
           (unwind-protect
                (progn
                  ,@registration-forms
                  (loop
                    ,@probe-forms
                    ,(when default-seen-p `(return-from ,block (locally ,@default-body)))
                    ,(if timeout
                         `(let ((remaining
                                  (and ,deadline
                                       (max 0.0d0
                                            (/ (- ,deadline (get-internal-real-time))
                                               (float internal-time-units-per-second 0.0d0))))))
                            (if (and remaining (zerop remaining))
                                (return-from ,block (locally ,@(cdr timeout)))
                                (wait-on-semaphore ,waiter :timeout remaining)))
                         `(wait-on-semaphore ,waiter))))
             ,@removal-forms)))))))))

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
clause's body returns.

Expanded entirely at compile time by %EXPAND-SELECT above: every clause's
TRY-SEND/TRY-RECV probe is inlined directly into the loop body below, so a
clause running is a direct call, not one more indirection through a stored
handler thunk looked up by GETF at runtime.

That inlining has one consequence worth knowing: a clause body sits inside
this macro's own probing LOOP, which -- like any LOOP -- establishes its own
implicit block named NIL. A bare (RETURN) inside a clause body exits *that*
loop, not one an enclosing form of the caller's own happens to have; it does
not escape to a caller-written (LOOP ...) wrapped around the whole SELECT
call the way it might look like it should. Use an explicit named BLOCK and
RETURN-FROM around the enclosing loop instead."
  (%expand-select clauses))
