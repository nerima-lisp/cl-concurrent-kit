;;;; cl-concurrent-kit.asd
(asdf:defsystem "cl-concurrent-kit"
  :description "Dependency-free, SBCL-only concurrency toolkit built directly on sb-thread"
  :long-description "cl-concurrent-kit wraps sb-thread/sb-ext into the small
set of primitives a portability layer like bordeaux-threads would offer
(threads, locks, condition variables, semaphores), then builds the
higher-level concurrency shapes found in modern languages on top of them:
promises/futures with explicit continuation-passing composition via
PROMISE-THEN (JS/Rust), CSP channels with a Go-style SELECT (Go/Kotlin), a
fixed-size executor (Java), and structured concurrency scopes with cooperative
cancellation (Kotlin/Swift/Python trio)."
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.2.0"
  :homepage "https://github.com/nerima-lisp/cl-concurrent-kit"
  :bug-tracker "https://github.com/nerima-lisp/cl-concurrent-kit/issues"
  :source-control (:git "https://github.com/nerima-lisp/cl-concurrent-kit.git")
  :depends-on ()
  :pathname "src"
  :serial t
  :components
  ((:file "package")
   (:file "conditions")
   (:file "primitives")
   (:file "fifo")
   (:file "promise")
   (:file "promise-combinators")
   (:file "channel")
   (:file "select")
   (:file "executor")
   (:file "scope-state")
   (:file "scope-execution")
   (:file "scope"))
  :in-order-to ((test-op (test-op "cl-concurrent-kit/test"))))

;;; The test system is `cl-concurrent-kit/test` (singular, slash-separated)
;;; with :pathname "t". It is NOT `cl-concurrent-kit-test`.
(asdf:defsystem "cl-concurrent-kit/test"
  :description "Test system for cl-concurrent-kit"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.2.0"
  :homepage "https://github.com/nerima-lisp/cl-concurrent-kit"
  :bug-tracker "https://github.com/nerima-lisp/cl-concurrent-kit/issues"
  :source-control (:git "https://github.com/nerima-lisp/cl-concurrent-kit.git")
  :depends-on ("cl-concurrent-kit" "cl-weave")
  :pathname "t"
  :serial t
  :components
  ((:file "package")
   (:file "conditions-test")
   (:file "primitives-test")
   (:file "promise-test")
   (:file "channel-test")
   (:file "select-test")
   (:file "executor-test")
   (:file "scope-test"))
  :perform (test-op (operation component)
             (declare (ignore operation component))
             (unless (funcall (symbol-function
                               (find-symbol "RUN-TESTS" "CL-CONCURRENT-KIT/TEST")))
               (error "cl-concurrent-kit test suite failed"))))
