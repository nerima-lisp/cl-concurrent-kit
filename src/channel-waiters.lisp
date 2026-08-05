;;;; src/channel-waiters.lisp
;;;;
;;;; Multi-channel waiter registration for SRC/CHANNEL.LISP's channels.
;;;;
;;;; A channel's own condition variables serve a thread blocked on that one
;;;; channel, and no thread can sleep on two of them at once. A SELECT clause
;;;; set spans several channels, so a multi-channel waiter brings its own
;;;; semaphore instead and registers it with each channel it watches;
;;;; whichever moves first signals it. That semaphore only says "something
;;;; changed" -- it never carries a value, so a woken waiter always re-probes
;;;; with TRY-RECV/TRY-SEND.
;;;;
;;;; INTERESTS narrows which transitions reach a given waiter: without it a
;;;; SELECT waiting only to receive would wake on every send that freed room
;;;; and re-probe its whole clause set for nothing. The rest of the
;;;; bookkeeping exists to keep that filter cheaper than the scan it replaces
;;;; -- WAITER-BUCKETS pre-partitions the semaphores by mask so a notification
;;;; touches only overlapping buckets instead of testing every waiter,
;;;; WAITER-INTERESTS unions the registered masks so an uncontended channel
;;;; dismisses the whole path with one LOGTEST, and WAITER-INTEREST-COUNTS
;;;; refcounts each bit so a removal clears it from that union only once the
;;;; last waiter holding it leaves. +CHANNEL-NOTIFY-CLOSE+ sits outside the
;;;; 3-bit interest space deliberately: a close ends every pending operation,
;;;; so it signals all eight buckets regardless of interest.
;;;;
;;;; SRC/SELECT.LISP registers one mask per clause over a set fixed at
;;;; macroexpansion time; SRC/STREAM-FAN-IN.LISP's %RUN-DYNAMIC-SELECT does
;;;; the same over a set that changes at runtime. Both must pair every
;;;; %CHANNEL-ADD-WAITER with a %CHANNEL-REMOVE-WAITER under UNWIND-PROTECT --
;;;; a leaked registration keeps a dead semaphore live in the channel's table
;;;; and goes on signaling it.
;;;;
;;;; This file loads AFTER src/channel.lisp and cannot be reordered: every
;;;; function below needs CHANNEL's DEFSTRUCT and the %WITH-CHANNEL-LOCK macro
;;;; at compile time. The +CHANNEL-NOTIFY-*+ constants and the %CHANNEL-NOTIFY
;;;; macro stay in src/channel.lisp for the mirror-image reason -- SEND,
;;;; TRY-SEND and CLOSE-CHANNEL expand them there.
(progn
  (in-package #:cl-concurrent-kit)
  (declaim (optimize (speed 3) (safety 1) (space 1) (debug 0) (compilation-speed 1))))

(defun %channel-waiter-bucket (channel interests)
  "Return the bucket for CHANNEL and the merged INTERESTS mask."
  (let ((buckets
        (or
          (channel-waiter-buckets channel)
          (setf (channel-waiter-buckets channel) (make-array 8 :initial-element nil)))))
    (or
      (aref buckets interests)
      (setf (aref buckets interests) (make-hash-table :test (function eq))))))

(defun %channel-notify-waiters (channel notifications close-p)
  (declare (type channel channel)
           (type (unsigned-byte 4) notifications)
           (type boolean close-p))
  (unless (or close-p (logtest notifications (channel-waiter-interests channel)))
    (return-from %channel-notify-waiters))
  (flet ((notify-bucket (interests)
           (let ((bucket (aref (channel-waiter-buckets channel) interests)))
          (when bucket
            (maphash
              (lambda (semaphore present-p)
                (declare (ignore present-p))
                (signal-semaphore semaphore))
              bucket)))))
    (if close-p (loop for interests fixnum from 0 below 8
            do (notify-bucket interests))
      (loop for interests fixnum from 1 below 8
            when (logtest notifications interests)
              do (notify-bucket interests)))))

(defun %channel-add-waiter (channel semaphore &optional (interests #b0111))
  "Register SEMAPHORE to be signaled when CHANNEL state matches INTERESTS."
  (declare (type channel channel)
           (type (unsigned-byte 3) interests))
  (check-type interests (unsigned-byte 3))
  (%with-channel-lock
    (channel)
    (multiple-value-bind (registered-interests present-p) (gethash semaphore (channel-waiters channel))
      (let* ((registered-interests
            (if present-p (the (unsigned-byte 3) registered-interests)
              0))
             (merged-interests
            (the (unsigned-byte 3) (logior registered-interests interests)))
             (new-interests
            (the (unsigned-byte 3) (logandc2 merged-interests registered-interests)))
             (changed-p (not (and present-p (= registered-interests merged-interests)))))
        (declare (type (unsigned-byte 3) registered-interests merged-interests new-interests))
        (when changed-p
          (when present-p
            (remhash semaphore (aref (channel-waiter-buckets channel) registered-interests)))
          (setf (gethash semaphore (channel-waiters channel)) merged-interests
                (gethash semaphore (%channel-waiter-bucket channel merged-interests)) t
                (channel-waiter-interests channel) (the
              (unsigned-byte 3)
              (logior (channel-waiter-interests channel) new-interests)))
          (loop for bit fixnum from 0 below 3
                when (logbitp bit new-interests)
                  do (incf (aref (channel-waiter-interest-counts channel) bit)))
          (unless present-p
            (incf (channel-waiter-count channel))))))))

(defun %channel-remove-waiter (channel semaphore)
  (%with-channel-lock
    (channel)
    (multiple-value-bind (interests present-p) (gethash semaphore (channel-waiters channel))
      (when present-p
        (remhash semaphore (channel-waiters channel))
        (remhash semaphore (aref (channel-waiter-buckets channel) interests))
        (loop for bit fixnum from 0 below 3
              when (logbitp bit interests)
                do (let ((remaining (decf (aref (channel-waiter-interest-counts channel) bit))))
            (when (zerop remaining)
              (setf (channel-waiter-interests channel) (the
                  (unsigned-byte 3)
                  (logandc2 (channel-waiter-interests channel) (ash 1 bit)))))))
        (decf (channel-waiter-count channel))))))

(declaim (optimize (speed 0) (safety 1) (space 1) (debug 1) (compilation-speed 1)))
