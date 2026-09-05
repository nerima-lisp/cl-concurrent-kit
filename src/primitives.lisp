;;;; src/primitives.lisp
;;;;
;;;; Low-level wrappers for SB-THREAD/SB-EXT threads, locks, condition
;;;; variables, semaphores, and atomic counters. Higher layers use this common
;;;; vocabulary instead of reaching into implementation packages directly.
(progn (in-package #:cl-concurrent-kit) (declaim (optimize (speed 3) (safety 1) (space 1) (debug 0) (compilation-speed 1))))

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
(deftype lock ()
  "The type of the object MAKE-LOCK returns and WITH-LOCK-HELD acquires: an
SB-THREAD:MUTEX. Named here because a consumer that wants to declare the type
of a slot or variable holding one -- (OR NULL CL-CONCURRENT-KIT:LOCK) in a
DEFSTRUCT slot, say -- otherwise has to write SB-THREAD:MUTEX and reach past
this package for the one thing the rest of it exists to wrap."
  'sb-thread:mutex)

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
(defvar *clock* (cl-boundary-kit:make-clock)
  "The CL-BOUNDARY-KIT:CLOCK consulted by deadline arithmetic
(%DEADLINE-FROM-TIMEOUT, %SECONDS-UNTIL-DEADLINE, and WITH-TIMEOUT's own
expiry check in src/timeout.lisp). Rebind to a CL-BOUNDARY-KIT:FAKE-CLOCK via
LET to make deadline arithmetic deterministic in tests. Real blocking waits
-- CONDITION-WAIT, WAIT-ON-SEMAPHORE, SB-EXT:WITH-TIMEOUT -- do not consult
this variable and cannot be sped up by advancing a fake clock bound here;
only the deadline math itself becomes testable this way.")
(defun %deadline-from-timeout (timeout)
  "Return an absolute *CLOCK* CLOCK-MONOTONIC value TIMEOUT seconds from now,
or NIL if TIMEOUT is NIL (no deadline)."
  (when timeout
    (+ (cl-boundary-kit:clock-monotonic *clock*) (round (* timeout internal-time-units-per-second)))))

(defun %seconds-until-deadline (deadline)
  "%DEADLINE-FROM-TIMEOUT's inverse: the number of seconds remaining until
DEADLINE (an absolute *CLOCK* CLOCK-MONOTONIC value), floored at 0.0d0 once
DEADLINE has already passed. DEADLINE must be non-NIL -- callers with an
optional deadline guard this themselves, since \"no deadline\" and \"zero
seconds remaining\" need different handling from whatever they pass the
result to next (SB-THREAD:CONDITION-WAIT and WAIT-ON-SEMAPHORE treat a NIL
:TIMEOUT as unbounded, not as already-expired)."
  (max 0.0d0
       (/ (- deadline (cl-boundary-kit:clock-monotonic *clock*))
          (float internal-time-units-per-second 0.0d0))))

(defmacro %wait-until ((condition-variable lock deadline) &body predicate-forms)
  "Wait with LOCK held until PREDICATE-FORMS produce a non-NIL value, and
return that value with LOCK still held.

CONDITION-VARIABLE, LOCK, and DEADLINE are evaluated once. PREDICATE-FORMS
expand directly into the loop body instead of being wrapped in a thunk, so
this costs no per-operation closure allocation on CHANNEL and PROMISE's hot
paths. SB-THREAD:CONDITION-WAIT always reacquires LOCK before returning, on a
timeout or otherwise, so this macro's :TIMEOUT return is itself within the
caller's WITH-LOCK-HELD dynamic extent, LOCK held -- callers that need to
clean up LOCK-protected state before signaling a timeout (CHANNEL's
unbuffered SEND is the one in this codebase) can rely on that."
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
                 (when ,deadline-var (%seconds-until-deadline ,deadline-var))))
           (unless (condition-wait ,condition-variable-var ,lock-var
                                   :timeout ,timeout-var)
             (return :timeout)))))))

(defmacro %with-deadline-wait ((result-var condition-variable lock deadline
                                timeout operation)
                               predicate-form &body body)
  "Bind RESULT-VAR to (%WAIT-UNTIL (CONDITION-VARIABLE LOCK DEADLINE)
PREDICATE-FORM) and run BODY. If the wait times out, signal
OPERATION-TIMED-OUT naming OPERATION and TIMEOUT instead of running BODY at
all.

DEADLINE and TIMEOUT are taken separately, not derived from one another here,
because a caller that waits more than once against the same overall budget --
CHANNEL's unbuffered SEND is the one in this codebase -- must compute
%DEADLINE-FROM-TIMEOUT exactly once and reuse it, while TIMEOUT (the original
seconds value) is needed again on every wait purely to report it. Callers
that wait only once typically write DEADLINE as
`(%deadline-from-timeout TIMEOUT)` inline.

A caller whose own cleanup must run under LOCK before a timeout is reported
should use %WAIT-UNTIL directly instead -- see its docstring."
  `(let ((,result-var (%wait-until (,condition-variable ,lock ,deadline) ,predicate-form)))
     (when (eq ,result-var :timeout)
       (error 'operation-timed-out :operation ,operation :timeout ,timeout))
     ,@body))
(declaim (optimize (speed 0) (safety 1) (space 1) (debug 1) (compilation-speed 1)))
