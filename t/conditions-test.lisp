;;;; t/conditions-test.lisp
(in-package #:cl-concurrent-kit/test)

(describe "condition reports"
  (it-each ((operation-timed-out "reports the operation and timeout"
        (:operation :recv :timeout 1.5d0) ("RECV"))
       (promise-already-fulfilled "reports the offending promise"
        (:promise :a-promise) ("already settled"))
       (channel-closed "reports the closed channel"
        (:channel :a-channel) ("closed channel"))
       (task-cancelled "reports the cancelled scope"
        (:scope :a-scope) ("cancelled"))
       (scope-error "reports the failure count and the first cause"
        (:causes :two-failures) ("2 task" "first"))
       (barrier-broken "reports the broken barrier"
        (:barrier :a-barrier) ("broken"))
       (promise-cancelled "reports the cancelled promise and its reason"
        (:promise :a-promise :reason :because) ("cancelled" "BECAUSE"))
       (promise-all-failed "reports the first cause"
        (:causes :two-failures) ("first")))
      "~A ~A"
      (type description initargs substrings)
    (declare (ignore description))
    ;; IT-EACH binds each row as quoted literal data, so an initarg that needs
    ;; a live object names one here rather than carrying it: a fresh object per
    ;; case, which is all these reports need since every one of them only
    ;; prints its subject rather than inspecting it.
    (flet ((live (value)
             (case value
               (:a-promise (make-promise))
               (:a-channel (make-channel))
               (:a-scope (cl-concurrent-kit::%make-task-scope))
               (:a-barrier (make-barrier 1))
               (:two-failures
                (list (make-condition 'simple-error :format-control "first")
                      (make-condition 'simple-error :format-control "second")))
               (t value))))
      (let ((condition (apply #'make-condition type
                              (loop for (key value) on initargs by #'cddr
                                    collect key
                                    collect (live value)))))
        (expect (princ-to-string condition) :to-satisfy
                (lambda (report)
                  (every (lambda (substring) (search substring report)) substrings))))))

  ;; Deliberately not a row above: this is the only one of these conditions
  ;; whose subject must be shut down again once the report has been read, and
  ;; the shared IT-EACH body has nowhere to put that teardown.
  (it "EXECUTOR-SHUT-DOWN reports the shut-down executor"
    (let* ((executor (make-executor :size 1))
           (condition (make-condition 'executor-shut-down :executor executor)))
      (unwind-protect
          (expect (princ-to-string condition) :to-satisfy
                  (lambda (report) (search "shut down" report)))
        (shutdown-executor executor :wait t)))))
