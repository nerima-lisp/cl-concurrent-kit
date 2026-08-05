;;;; src/channel.lisp
;;;;
;;;; A CSP-style channel. BUFFER-SIZE 0 is Go's unbuffered channel: SEND
;;;; blocks until a RECV has actually taken the value back out, so SEND
;;;; returning is a synchronization point, not just "enqueued somewhere".
;;;; BUFFER-SIZE N > 0 is a bounded queue: SEND only blocks once N values are
;;;; already waiting. Both share one implementation below by treating
;;;; unbuffered as "capacity 1, and SEND additionally waits for the drain".
(progn
  (in-package #:cl-concurrent-kit)
  (declaim (optimize (speed 3) (safety 1) (space 1) (debug 0) (compilation-speed 1)))
  (declaim (inline %channel-buffer-push
                   %channel-buffer-pop
                   %channel-remove-unbuffered-message)))

(defstruct (channel (:constructor %make-channel (buffer-size capacity buffer)))
  (lock (make-lock :name "cl-concurrent-kit channel") :read-only t)
  (send-condition-variable
    (make-condition-variable :name "cl-concurrent-kit channel send")
    :read-only t)
  (recv-condition-variable
    (make-condition-variable :name "cl-concurrent-kit channel recv")
    :read-only t)
  (rendezvous-condition-variable
    (make-condition-variable :name "cl-concurrent-kit channel rendezvous")
    :read-only t)
  (buffer-size 0 :read-only t :type (integer 0 #.most-positive-fixnum))
  (capacity 1 :read-only t :type (integer 1 #.most-positive-fixnum))
  (buffer nil :read-only t :type (simple-array t (*)))
  (head 0 :type (integer 0 #.most-positive-fixnum))
  (tail 0 :type (integer 0 #.most-positive-fixnum))
  (count 0 :type (integer 0 #.most-positive-fixnum))
  (rendezvous-generation 0 :type (integer 0 #.most-positive-fixnum))
  (closed-p nil)
  (waiters (make-hash-table :test (function eq)) :read-only t)
  (waiter-buckets nil :type (or null (simple-array t (8))))
  (waiter-interest-counts
    (make-array 3 :element-type (quote fixnum) :initial-element 0)
    :type
    (simple-array fixnum (3)))
  (waiter-interests 0 :type (unsigned-byte 3))
  (waiter-count 0 :type fixnum))

(defmacro %with-channel-lock ((channel) &body body)
  "Hold CHANNEL's own lock for the dynamic extent of BODY."
  `(with-lock-held ((channel-lock ,channel)) ,@body))

(setf (documentation 'channel-closed-p 'function) "True once CLOSE-CHANNEL has been called on CHANNEL. A momentary,
lock-free read -- like THREAD-ALIVE-P, treat it as advisory rather than
linearized with concurrent SEND/RECV.")

(progn
  (defun %channel-buffer-push (channel entry)
    (declare (type channel channel))
    (let ((tail (channel-tail channel))
          (capacity (channel-capacity channel)))
      (setf (aref (channel-buffer channel) tail) entry
            (channel-tail channel) (if (= tail (1- capacity)) 0
          (1+ tail)))
      (incf (channel-count channel)))
    channel)
  (defun %channel-buffer-pop (channel)
    (declare (type channel channel))
    (let ((head (channel-head channel))
          (capacity (channel-capacity channel)))
      (prog1
        (aref (channel-buffer channel) head)
        (setf (aref (channel-buffer channel) head) nil
              (channel-head channel) (if (= head (1- capacity)) 0
            (1+ head)))
        (decf (channel-count channel)))))
  (defun %channel-remove-unbuffered-message (channel)
  (declare (type channel channel))
  (when (plusp (channel-count channel))
    (%channel-buffer-pop channel)
    t))
  (defun make-channel (&key (buffer-size 0))
    "Create a channel. BUFFER-SIZE 0 (the default) is an unbuffered, CSP-style rendezvous channel: SEND blocks until a RECV takes the value. BUFFER-SIZE N > 0 lets up to N values queue up before SEND blocks."
    (check-type buffer-size (integer 0 #.most-positive-fixnum))
    (let ((capacity (max 1 buffer-size)))
      (%make-channel buffer-size capacity (make-array capacity)))))

;;; State-transition notification
;;;
;;; One mask names which transitions a locked state change makes possible, so
;;; SEND/RECV/CLOSE-CHANNEL each describe what they did once and %CHANNEL-NOTIFY
;;; works out who to wake. The bits below 8 are also the interest vocabulary a
;;; multi-channel waiter registers with; +CHANNEL-NOTIFY-CLOSE+ sits outside
;;; that 3-bit space deliberately, since a close ends every pending operation
;;; regardless of interest.
;;;
;;; %CHANNEL-NOTIFY handles this channel's own condition variables inline and
;;; tail-calls %CHANNEL-NOTIFY-WAITERS -- defined in SRC/CHANNEL-WAITERS.LISP,
;;; which loads after this file -- only when a waiter is actually registered.
;;; The constants and the macro stay here rather than moving with the rest of
;;; the waiter subsystem because SEND, TRY-SEND, %CHANNEL-DEQUEUE and
;;; CLOSE-CHANNEL below expand them at compile time.
(defconstant +channel-notify-send+ #b0001)

(defconstant +channel-notify-recv+ #b0010)

(defconstant +channel-notify-rendezvous+ #b0100)

(defconstant +channel-notify-close+ #b1000)

(defmacro %channel-notify (channel notifications)
  "Notify waiters affected by a locked CHANNEL state transition."
  (let ((channel-var (gensym "CHANNEL-"))
        (notifications-var (gensym "NOTIFICATIONS-"))
        (close-p-var (gensym "CLOSE-P-")))
    `(let* ((,channel-var ,channel)
            (,notifications-var ,notifications)
            (,close-p-var (logtest +channel-notify-close+ ,notifications-var)))
       (declare (type channel ,channel-var)
                (type (unsigned-byte 4) ,notifications-var))
       (if ,close-p-var (progn
                          (condition-broadcast (channel-send-condition-variable ,channel-var))
                          (condition-broadcast (channel-recv-condition-variable ,channel-var))
                          (condition-broadcast (channel-rendezvous-condition-variable ,channel-var)))
           (progn
             (when (logtest +channel-notify-send+ ,notifications-var)
               (condition-notify (channel-send-condition-variable ,channel-var)))
             (when (logtest +channel-notify-recv+ ,notifications-var)
               (condition-notify (channel-recv-condition-variable ,channel-var)))
             (when (logtest +channel-notify-rendezvous+ ,notifications-var)
               (condition-notify (channel-rendezvous-condition-variable ,channel-var)))))
       (when (plusp (channel-waiter-count ,channel-var))
         (%channel-notify-waiters ,channel-var ,notifications-var ,close-p-var)))))

(defun send (channel value &key timeout)
  "Send VALUE on CHANNEL, blocking while it is full (buffered) or until a RECV
takes VALUE back out (unbuffered). With TIMEOUT (a CL-DATE-KIT:DURATION),
signals OPERATION-TIMED-OUT if it does not complete in time. Signals
CHANNEL-CLOSED if CHANNEL is already closed."
  (declare (type channel channel))
  (let ((timeout (and timeout (cl-date-kit:duration-to-seconds timeout))))
    (%with-channel-lock (channel)
      (let* ((deadline (%deadline-from-timeout timeout))
             (unbuffered-p (zerop (channel-buffer-size channel)))
             (generation nil)
             (capacity (channel-capacity channel)))
        (%with-deadline-wait (room (channel-send-condition-variable channel) (channel-lock channel)
                              deadline timeout :send)
            (cond
              ((channel-closed-p channel) :closed)
              ((< (channel-count channel) capacity) :ready))
          (when (eq room :closed)
            (error 'channel-closed :channel channel)))
        (when unbuffered-p
          (setf generation (channel-rendezvous-generation channel)))
        (%channel-buffer-push channel value)
        (%channel-notify channel +channel-notify-recv+)
        (when (and unbuffered-p
                   (eq :timeout
                       (%wait-until ((channel-rendezvous-condition-variable channel) (channel-lock channel) deadline)
                         (/= generation (channel-rendezvous-generation channel))))
                   (= generation (channel-rendezvous-generation channel)))
          (when (%channel-remove-unbuffered-message channel)
            (%channel-notify channel +channel-notify-send+))
          (error 'operation-timed-out :operation :send :timeout timeout))))
    t))

(defun %channel-dequeue (channel)
  "Pop CHANNEL's next queued entry, update COUNT and an unbuffered entry's
RENDEZVOUS-GENERATION, and notify whichever waiters that transition unblocks,
then return the value itself. Shared by RECV and TRY-RECV below, which differ
only in how they wait for something to dequeue in the first place -- CHANNEL
must already have a value available (COUNT plusp) under CHANNEL's own lock;
neither caller calls this otherwise."
  (declare (type channel channel))
  (let ((entry (%channel-buffer-pop channel))
        (unbuffered-p (zerop (channel-buffer-size channel))))
    (when unbuffered-p
      (incf (channel-rendezvous-generation channel)))
    (%channel-notify channel
                      (if unbuffered-p
                          (logior +channel-notify-send+ +channel-notify-rendezvous+)
                          +channel-notify-send+))
    entry))

(defun recv (channel &key timeout)
  "Receive a value from CHANNEL, blocking until one is available or CHANNEL
is closed. Returns (VALUES VALUE T), or (VALUES NIL NIL) once CHANNEL is
closed and every value sent before the close has been drained. With TIMEOUT
(a CL-DATE-KIT:DURATION), signals OPERATION-TIMED-OUT if neither happens in
time."
  (declare (type channel channel))
  (let ((timeout (and timeout (cl-date-kit:duration-to-seconds timeout))))
    (%with-channel-lock (channel)
      (%with-deadline-wait (ready (channel-recv-condition-variable channel) (channel-lock channel)
                            (%deadline-from-timeout timeout) timeout :recv)
          (cond
            ((plusp (channel-count channel)) :ready)
            ((channel-closed-p channel) :closed))
        (case ready
          (:closed (values nil nil))
          (:ready (values (%channel-dequeue channel) t)))))))

(defun try-send (channel value)
  "Non-blocking SEND: deposit VALUE and return T if room is immediately
available, else return NIL. Unlike SEND, does not wait for an unbuffered
channel value to actually be received. Signals CHANNEL-CLOSED if CHANNEL is
already closed."
  (declare (type channel channel))
  (%with-channel-lock (channel)
    (when (channel-closed-p channel)
      (error 'channel-closed :channel channel))
    (when (< (channel-count channel) (channel-capacity channel))
      (%channel-buffer-push channel value)
      (%channel-notify channel +channel-notify-recv+)
      t)))

(defun try-recv (channel)
  "Non-blocking RECV. Returns (VALUES VALUE T NIL) if a value was
immediately available, (VALUES NIL NIL T) if CHANNEL is closed and every
buffered value has been drained, or (VALUES NIL NIL NIL) if nothing is
available right now but CHANNEL may still produce more."
  (declare (type channel channel))
  (%with-channel-lock (channel)
    (cond
      ((plusp (channel-count channel)) (values (%channel-dequeue channel) t nil))
      ((channel-closed-p channel) (values nil nil t))
      (t (values nil nil nil)))))

(defun close-channel (channel)
  "Close CHANNEL: further SEND or TRY-SEND calls signal CHANNEL-CLOSED, but
RECV/TRY-RECV keep draining any values already queued. Idempotent."
  (declare (type channel channel))
  (%with-channel-lock
    (channel)
    (unless (channel-closed-p channel)
      (setf (channel-closed-p channel) t)
      (%channel-notify channel +channel-notify-close+)))
  channel)

(declaim (optimize (speed 0) (safety 1) (space 1) (debug 1) (compilation-speed 1)))
