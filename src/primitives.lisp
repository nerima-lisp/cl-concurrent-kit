;;;; src/primitives.lisp
;;;;
;;;; The layer bordeaux-threads would occupy in a portable stack: threads,
;;;; locks, condition variables, semaphores, and atomic counters, each a thin
;;;; wrapper over SB-THREAD/SB-EXT. Nothing here has implementation-specific
;;;; behavior beyond what SB-THREAD already documents; the wrapping exists so
;;;; the rest of this package (and its callers) name one vocabulary instead of
;;;; reaching into SB-THREAD directly.
(progn
  (declaim
    (optimize (speed 3) (safety 1) (debug 0) (compilation-speed 0)
              #+sb-cover (sb-c:store-coverage-data 3)))
  (in-package #:cl-concurrent-kit))

#-sb-cover (declaim (inline current-thread thread-name thread-alive-p condition-wait condition-notify condition-broadcast wait-on-semaphore signal-semaphore atomic-counter-incf atomic-counter-decf %deadline-from-timeout))

;;; Threads
(defun make-thread (function &key name arguments)
  "Run FUNCTION on a new thread named NAME, passing it ARGUMENTS (a list,
applied as in APPLY). Returns the new SB-THREAD:THREAD immediately; the
thread's return values are collected by JOIN-THREAD."
  (sb-thread:make-thread function :name name :arguments arguments))

(defun current-thread ()
  "The SB-THREAD:THREAD object for the calling thread."
  sb-thread:*current-thread*)

(defun thread-name (thread)
  "THREAD's name, as given to MAKE-THREAD."
  (sb-thread:thread-name thread))

(defun thread-alive-p (thread)
  "True while THREAD's function has not yet returned or aborted."
  (sb-thread:thread-alive-p thread))

(defun join-thread (thread &key (default nil defaultp) timeout)
  "Block until THREAD exits and return the values its function returned. If
THREAD exits abnormally (an uncaught condition) or TIMEOUT elapses first,
return DEFAULT when supplied; otherwise signal SB-THREAD:JOIN-THREAD-ERROR."
  (if defaultp (sb-thread:join-thread thread :default default :timeout timeout)
    (sb-thread:join-thread thread :timeout timeout)))

;;; Locks
(defun make-lock (&key name)
  "Create a mutex named NAME."
  (sb-thread:make-mutex :name name))

(defmacro with-lock-held ((lock) &body body)
  "Hold LOCK for the dynamic extent of BODY."
  `(sb-thread:with-mutex (,lock) ,@body))

;;; Condition variables
(defun make-condition-variable (&key name)
  "Create a condition variable named NAME, used with a lock via
CONDITION-WAIT/CONDITION-NOTIFY/CONDITION-BROADCAST."
  (sb-thread:make-waitqueue :name name))

(defun condition-wait (condition-variable lock &key timeout)
  "Atomically release LOCK and wait on CONDITION-VARIABLE until CONDITION-NOTIFY or CONDITION-BROADCAST wakes this thread, then reacquire LOCK before returning. LOCK must be held by this thread on entry.

Spurious wakeups are possible -- callers must loop, rechecking the condition they are actually waiting for.

When TIMEOUT (seconds) elapses, return NIL with LOCK held. Otherwise return T with LOCK held."
  (sb-thread:condition-wait condition-variable lock :timeout timeout))

(defun condition-notify (condition-variable)
  "Wake one thread waiting on CONDITION-VARIABLE. LOCK must be held by this
thread; see CONDITION-WAIT."
  (sb-thread:condition-notify condition-variable)
  (values))

(defun condition-broadcast (condition-variable)
  "Wake every thread waiting on CONDITION-VARIABLE. LOCK must be held by this
thread; see CONDITION-WAIT."
  (sb-thread:condition-broadcast condition-variable)
  (values))

;;; Semaphores
(defun make-semaphore (&key name (count 0))
  "Create a semaphore named NAME with initial count COUNT."
  (sb-thread:make-semaphore :name name :count count))

(defun wait-on-semaphore (semaphore &key timeout)
  "Decrement SEMAPHORE's count by one, blocking while it is zero. Returns the
new count on success, or NIL if TIMEOUT (seconds) elapses first."
  (sb-thread:wait-on-semaphore semaphore :timeout timeout))

(defun signal-semaphore (semaphore &optional (n 1))
  "Increment SEMAPHORE's count by N, waking up to N threads blocked in
WAIT-ON-SEMAPHORE."
  (sb-thread:signal-semaphore semaphore n)
  (values))

;;; Atomic counters
;;;
;;; SB-EXT:ATOMIC-INCF/ATOMIC-DECF only admit a (UNSIGNED-BYTE 64) structure
;;; slot (a FIXNUM slot is rejected outright -- confirmed against SBCL 2.6.0),
;;; so ATOMIC-COUNTER is scoped to non-negative counting such as "tasks
;;; currently outstanding", where increments and decrements are paired and the
;;; count never needs to go negative.
(defstruct (atomic-counter (:constructor %make-atomic-counter (value))) (value 0 :type (unsigned-byte 64)))

(defun make-atomic-counter (&optional (initial-value 0))
  "Create an ATOMIC-COUNTER starting at INITIAL-VALUE."
  (%make-atomic-counter initial-value))

(defun atomic-counter-incf (counter &optional (delta 1))
  "Atomically add DELTA to COUNTER's value and return the new value."
  (sb-ext:atomic-incf (atomic-counter-value counter) delta))

(defun atomic-counter-decf (counter &optional (delta 1))
  "Atomically subtract DELTA from COUNTER's value and return the new value."
  (sb-ext:atomic-decf (atomic-counter-value counter) delta))

;;; Deadline-based waiting
;;;
;;; Shared by PROMISE, CHANNEL, and SELECT's blocking implementations: turns a
;;; caller-facing :TIMEOUT argument in seconds into a single absolute deadline
;;; computed once, so a loop that wakes up repeatedly (spurious wakeups,
;;; broadcasts meant for a different waiter) converges on the same deadline
;;; instead of restarting a fresh N-second wait on every iteration.
(defun %deadline-from-timeout (timeout)
  "Return an absolute GET-INTERNAL-REAL-TIME value TIMEOUT seconds from now,
or NIL if TIMEOUT is NIL (no deadline)."
  (when timeout
    (+ (get-internal-real-time) (round (* timeout internal-time-units-per-second)))))

(defmacro %wait-until ((condition-variable lock deadline) &body predicate-forms)
  "Wait with LOCK held until PREDICATE-FORMS produce a non-NIL value.

The condition variable, lock, and deadline forms are evaluated once. The expanded predicate runs directly in the caller, avoiding a per-operation thunk allocation on channel and promise hot paths. SB-THREAD:CONDITION-WAIT always returns with LOCK held; this macro therefore returns :TIMEOUT within the caller's WITH-LOCK-HELD dynamic extent."
  (let* ((condition-variable-var (gensym "CONDITION-VARIABLE-"))
         (lock-var (gensym "LOCK-"))
         (deadline-var (gensym "DEADLINE-"))
         (result-var (gensym "RESULT-"))
         (timeout-var (gensym "TIMEOUT-"))
         (predicate-form
          (if (rest predicate-forms)
              (cons 'progn predicate-forms)
              (first predicate-forms))))
    `(let ((,condition-variable-var ,condition-variable)
           (,lock-var ,lock)
           (,deadline-var ,deadline))
       (loop
         (let ((,result-var ,predicate-form))
           (when ,result-var
             (return ,result-var)))
         (let ((,timeout-var
                 (when ,deadline-var
                   (max 0.0d0
                        (/ (- ,deadline-var (get-internal-real-time))
                           (float internal-time-units-per-second 0.0d0))))))
           (unless (condition-wait ,condition-variable-var ,lock-var
                                   :timeout ,timeout-var)
             (return :timeout)))))))
