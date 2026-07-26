;;;; t/scope-test.lisp
(in-package #:cl-concurrent-kit/test)

(describe "with-task-scope"
  (it "returns the body's value when every task succeeds"
    (expect (with-task-scope (scope) (declare (ignore scope)) :done) :to-be :done))

  (it "waits for every spawned task to finish before returning"
    (let ((finished (list))
          (lock (make-lock)))
      (with-task-scope (scope)
        ;; DOTIMES mutates one binding of I in place, so each closure needs
        ;; its own copy via LET -- otherwise every task would see I already
        ;; at 5 by the time a thread got around to running it.
        (dotimes (i 5)
          (let ((i i))
            (spawn scope (lambda ()
                           (sleep (* i 0.01))
                           (with-lock-held (lock) (push i finished)))))))
      (expect (sort finished #'<) :to-equal '(0 1 2 3 4))))

  (it "makes each SPAWNed task's own result available via its returned promise"
    (with-task-scope (scope)
      (let ((p (spawn scope (lambda () (+ 20 22)))))
        (expect (await p) :to-be 42))))

  (it "signals SCOPE-ERROR wrapping a failed task's condition"
    (signals scope-error
      (with-task-scope (scope)
        (spawn scope (lambda () (error "task boom")))))
    (handler-case
        (with-task-scope (scope)
          (spawn scope (lambda () (error "task boom"))))
      (scope-error (c)
        (expect (length (scope-error-causes c)) :to-be 1))))

  (it "propagates the body's own error instead of wrapping it in SCOPE-ERROR"
    (signals simple-error
      (with-task-scope (scope)
        (declare (ignore scope))
        (error "body boom"))))

  (it "trips CHECK-CANCELLED for other tasks once a sibling fails"
    (let ((cancelled-observed-p nil))
      (signals scope-error
        (with-task-scope (scope)
          (spawn scope (lambda () (error "sibling failure")))
          (spawn scope
                 (lambda ()
                   (loop repeat 100
                         do (sleep 0.01)
                            (handler-case (check-cancelled scope)
                              (task-cancelled ()
                                (setf cancelled-observed-p t)
                                (return))))))))
      (expect cancelled-observed-p :to-be-truthy))))
