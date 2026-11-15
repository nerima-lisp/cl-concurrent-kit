;;;; Standalone child: signal-handler changes cannot affect the test runner.
(require :asdf)
(require :sb-posix)
(let ((source (first (uiop:command-line-arguments))))
  (asdf:load-asd source)
  (asdf:load-system "cl-concurrent-kit"))

(let (target (handler-count 0))
  (sb-sys:enable-interrupt
   sb-unix:sigusr1
   (lambda (&rest arguments)
     (declare (ignore arguments))
     (incf handler-count)
     (sb-sys:with-interrupts
       ;; REQUEST must be last: its transfer can occur inside this handler.
       (cl-concurrent-kit:request-interruption target :reason :posix))))
  (let ((condition
          (handler-case
              (cl-concurrent-kit:with-interruptible-scope (scope)
                (setf target scope)
                ;; Exclude process/ASDF startup from the runtime join deadline.
                (format t "K2-POSIX-READY~%")
                (finish-output)
                (read-char)
                (sb-posix:kill (sb-posix:getpid) sb-unix:sigusr1)
                (loop (sleep 0.1)))
            (cl-concurrent-kit:operation-interrupted (condition) condition))))
    (assert (= handler-count 1))
    (assert (typep condition 'cl-concurrent-kit:operation-interrupted))
    (assert (eq (cl-concurrent-kit:operation-interrupted-scope condition) target))
    (assert (eq (cl-concurrent-kit:operation-interrupted-reason condition) :posix))
    (format t "POSIX last-action interruption verified~%")))
