;;;; benchmarks/run-benchmarks.lisp
;;;;
;;;; Characterizes each primitive's own overhead using cl-weave's BENCHMARK
;;;; rather than a hand-rolled timing loop, so these numbers stay directly
;;;; comparable to any other cl-weave-benchmarked SBCL library. Run with:
;;;;   nix develop -c sbcl --script benchmarks/run-benchmarks.lisp

(require :asdf)

(defun script-directory ()
  (make-pathname :name nil
                 :type nil
                 :defaults (or *load-truename*
                               *compile-file-truename*
                               (error "Unable to determine the script location"))))

(let ((root (merge-pathnames "../" (script-directory))))
  (asdf:initialize-source-registry
   `(:source-registry (:tree ,root) :inherit-configuration)))

(asdf:load-system "cl-concurrent-kit")
(asdf:load-system "cl-weave")

(in-package #:cl-concurrent-kit)

(defun %report-benchmark (name result)
  (format t "~&~A~40T median=~,4Fms mean=~,4Fms min=~,4Fms max=~,4Fms~%"
          name
          (cl-weave:median-ms result)
          (cl-weave:mean-ms result)
          (cl-weave:minimum-ms result)
          (cl-weave:maximum-ms result)))

(%report-benchmark
 "atomic-counter-incf, 1000 increments"
 (let ((counter (make-atomic-counter)))
   (cl-weave:benchmark (:warmup 100 :samples 20 :iterations 1000)
     (atomic-counter-incf counter))))

(%report-benchmark
 "buffered-channel send+recv round-trip, 1000 pairs"
 (let ((channel (make-channel :buffer-size 1)))
   (cl-weave:benchmark (:warmup 100 :samples 20 :iterations 1000)
     (send channel :x)
     (recv channel))))

(%report-benchmark
 "promise deliver+await round-trip, 1000 pairs"
 (cl-weave:benchmark (:warmup 100 :samples 20 :iterations 1000)
   (let ((promise (make-promise)))
     (deliver promise :x)
     (await promise))))

(%report-benchmark
 "promise-then continuation registration, 1000 pairs"
 (cl-weave:benchmark (:warmup 100 :samples 20 :iterations 1000)
   (let ((promise (make-promise)))
     (deliver promise :x)
     (await (promise-then promise (function identity))))))

(let ((executor (make-executor :size 4)))
  (unwind-protect
      (%report-benchmark
       "executor submit+await round-trip, 200 tasks"
       (cl-weave:benchmark (:warmup 50 :samples 20 :iterations 200)
         (await (submit executor (lambda () :x)))))
    (shutdown-executor executor :wait t)))

(%report-benchmark
 "with-task-scope spawn+await round-trip (thread child), 200 scopes"
 (cl-weave:benchmark (:warmup 50 :samples 20 :iterations 200)
   (with-task-scope (scope)
     (await (spawn scope (lambda () :x))))))

(uiop:quit 0)
