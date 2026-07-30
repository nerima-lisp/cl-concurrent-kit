;;;; t/conditions-test.lisp
(in-package #:cl-concurrent-kit/test)

(describe "condition reports"
  (it "OPERATION-TIMED-OUT reports the operation and timeout"
    (let ((condition (make-condition 'operation-timed-out :operation :recv :timeout 1.5d0)))
      (expect (princ-to-string condition) :to-satisfy
              (lambda (report) (search "RECV" report)))))

  (it "PROMISE-ALREADY-FULFILLED reports the offending promise"
    (let* ((promise (make-promise))
           (condition (make-condition 'promise-already-fulfilled :promise promise)))
      (expect (princ-to-string condition) :to-satisfy
              (lambda (report) (search "already settled" report)))))

  (it "CHANNEL-CLOSED reports the closed channel"
    (let* ((channel (make-channel))
           (condition (make-condition 'channel-closed :channel channel)))
      (expect (princ-to-string condition) :to-satisfy
              (lambda (report) (search "closed channel" report)))))

  (it "EXECUTOR-SHUT-DOWN reports the shut-down executor"
    (let* ((executor (make-executor :size 1))
           (condition (make-condition 'executor-shut-down :executor executor)))
      (unwind-protect
          (expect (princ-to-string condition) :to-satisfy
                  (lambda (report) (search "shut down" report)))
        (shutdown-executor executor :wait t))))

  (it "TASK-CANCELLED reports the cancelled scope"
    (let* ((scope (cl-concurrent-kit::%make-task-scope))
           (condition (make-condition 'task-cancelled :scope scope)))
      (expect (princ-to-string condition) :to-satisfy
              (lambda (report) (search "cancelled" report)))))

  (it "SCOPE-ERROR reports the failure count and the first cause"
    (let ((condition (make-condition 'scope-error
                                      :causes (list (make-condition 'simple-error
                                                                     :format-control "first")
                                                     (make-condition 'simple-error
                                                                     :format-control "second")))))
      (expect (princ-to-string condition) :to-satisfy
              (lambda (report) (and (search "2 task" report) (search "first" report)))))))
