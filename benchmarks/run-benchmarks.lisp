;;;; benchmarks/run-benchmarks.lisp
;;;;
;;;; Benchmark the public primitives with cl-weave's BENCHMARK. Run with:
;;;;   nix develop -c sbcl --script benchmarks/run-benchmarks.lisp

(require :asdf)

(defun script-directory ()
  (make-pathname :name nil
                 :type nil
                 :defaults (or *load-truename*
                               *compile-file-truename*
                               (error "Unable to determine the script location"))))

(defun source-root ()
  "This project's own root, honoring CL_CONCURRENT_KIT_SOURCE_ROOT when set --
necessary when this script itself runs from a location that is not the
project root, e.g. copied into the Nix store as its own derivation by
flake.nix's benchmark check/app."
  (or
   (let ((value (uiop:getenv "CL_CONCURRENT_KIT_SOURCE_ROOT")))
     (and value (uiop:ensure-directory-pathname value)))
   (merge-pathnames "../" (script-directory))))

(asdf:initialize-source-registry
 `(:source-registry (:tree ,(source-root)) :inherit-configuration))

(asdf:load-system "cl-concurrent-kit")
(asdf:load-system "cl-weave")
(asdf:load-system "cl-cli")

(in-package #:cl-concurrent-kit)

(defun %report-benchmark (name result)
  (format t "~&~A~40T median=~,4Fms mean=~,4Fms min=~,4Fms max=~,4Fms~%"
          name
          (cl-weave:median-ms result)
          (cl-weave:mean-ms result)
          (cl-weave:minimum-ms result)
          (cl-weave:maximum-ms result)))

;; Each entry is (NAME BASE-ITERATIONS THUNK), THUNK a one-argument function
;; of the actual iteration count (BASE-ITERATIONS scaled by --SCALE) that
;; runs CL-WEAVE:BENCHMARK and returns its result. Separating this table from
;; %RUN-BENCHMARKS below is what lets --ONLY skip a non-matching entry
;; without ever running its THUNK, and SCALE apply uniformly without each
;; entry repeating the same multiplication.
(defparameter *benchmarks*
  (list
   (list "atomic-counter-incf, 1000 increments" 1000
         (lambda (iterations)
           (let ((counter (make-atomic-counter)))
             (cl-weave:benchmark (:warmup 100 :samples 20 :iterations iterations)
               (atomic-counter-incf counter)))))
   (list "buffered-channel send+recv round-trip, 1000 pairs" 1000
         (lambda (iterations)
           (let ((channel (make-channel :buffer-size 1)))
             (cl-weave:benchmark (:warmup 100 :samples 20 :iterations iterations)
               (send channel :x)
               (recv channel)))))
   (list "select-ready-recv, 1000 pairs" 1000
         (lambda (iterations)
           (let ((channel (make-channel :buffer-size 1)))
             (cl-weave:benchmark (:warmup 100 :samples 20 :iterations iterations)
               (send channel :x)
               (select ((recv channel) (value) value))))))
   (list "promise deliver+await round-trip, 1000 pairs" 1000
         (lambda (iterations)
           (cl-weave:benchmark (:warmup 100 :samples 20 :iterations iterations)
             (let ((promise (make-promise)))
               (deliver promise :x)
               (await promise)))))
   (list "promise-then continuation registration, 1000 pairs" 1000
         (lambda (iterations)
           (cl-weave:benchmark (:warmup 100 :samples 20 :iterations iterations)
             (let ((promise (make-promise)))
               (deliver promise :x)
               (await (promise-then promise (function identity)))))))
   (list "executor submit+await round-trip, 200 tasks" 200
         (lambda (iterations)
           (let ((executor (make-executor :size 4)))
             (unwind-protect
                 (cl-weave:benchmark (:warmup 50 :samples 20 :iterations iterations)
                   (await (submit executor (lambda () :x))))
               (shutdown-executor executor :wait t)))))
   (list "with-task-scope spawn+await round-trip (thread child), 200 scopes" 200
         (lambda (iterations)
           (cl-weave:benchmark (:warmup 50 :samples 20 :iterations iterations)
             (with-task-scope (scope)
               (await (spawn scope (lambda () :x)))))))))

(defun %run-benchmarks (only scale)
  "Run every entry of *BENCHMARKS* whose name contains ONLY as a substring
(every entry, when ONLY is NIL), each with its own BASE-ITERATIONS multiplied
by SCALE and floored at 1."
  (dolist (entry *benchmarks*)
    (destructuring-bind (name base-iterations thunk) entry
      (when (or (null only) (search only name))
        (%report-benchmark name (funcall thunk (max 1 (round (* scale base-iterations)))))))))

(defparameter *app*
  (cl-cli:make-app
   :name "cl-concurrent-kit-benchmark"
   :summary "Microbenchmarks for cl-concurrent-kit's own primitives"
   :global-options
   (list (cl-cli:make-option :key :only :name "only" :kind :value
                             :description "Only run benchmarks whose name contains this substring"))
   :positionals
   (list (cl-cli:make-positional :key :scale :type :number :default 1
                                  :description "Multiply every benchmark's own iteration count by this factor"))
   :handler (lambda (invocation)
              (%run-benchmarks (cl-cli:option-value invocation :only)
                                (cl-cli:positional-value invocation :scale 1))
              0)))

(uiop:quit (cl-cli:run-app *app* :argv (cons "cl-concurrent-kit-benchmark" (uiop:command-line-arguments))))
