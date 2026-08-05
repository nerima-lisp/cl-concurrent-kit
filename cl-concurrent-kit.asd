;;;; cl-concurrent-kit.asd

;;; This form comes FIRST, before any defsystem. ASDF binds *package* to
;;; ASDF-USER only for a file it loads itself; read any other way -- a REPL
;;; `load`, an editor evaluating the buffer, flake.nix parsing :version -- the
;;; file is read in whatever package happens to be current. Saying it makes
;;; the file self-contained.
(in-package #:asdf-user)

(asdf:defsystem "cl-concurrent-kit"
  :description "SBCL-only concurrency toolkit built directly on sb-thread, using CL-DATE-KIT durations and CL-BOUNDARY-KIT clock injection for deadline arithmetic"
  :long-description "cl-concurrent-kit wraps sb-thread/sb-ext into the small
set of primitives a portability layer like bordeaux-threads would offer
(threads, locks, condition variables, semaphores), then builds the
higher-level concurrency shapes found in modern languages on top of them:
promises/futures with explicit continuation-passing composition via
PROMISE-THEN (JS/Rust), CSP channels with a Go-style SELECT (Go/Kotlin), a
fixed-size executor (Java), and structured concurrency scopes with cooperative
cancellation (Kotlin/Swift/Python trio). Every :TIMEOUT argument across the
library accepts a CL-DATE-KIT:DURATION; CL-BOUNDARY-KIT supplies the
injectable clock behind the deadline arithmetic that measures it."
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.6.0"
  :homepage "https://github.com/nerima-lisp/cl-concurrent-kit"
  :bug-tracker "https://github.com/nerima-lisp/cl-concurrent-kit/issues"
  :source-control (:git "https://github.com/nerima-lisp/cl-concurrent-kit.git")
  :depends-on ("cl-boundary-kit" "cl-date-kit")
  :pathname "src"
  :serial t
  ;; SPEED 0 for THIS system's own files and no one else's.
  ;;
  ;; Why the policy exists: SPEED 1 (SBCL's default) is what a bisection
  ;; originally implicated in a compile that did not return, in SBCL 2.6.0's
  ;; constraint-propagation pass over src/scope.lisp's SPAWN-CHILD once
  ;; src/select.lisp, src/executor.lisp and src/scope-state.lisp had all
  ;; already contributed type information to the same image. This
  ;; lock-and-condition-variable coordination code is never the bottleneck a
  ;; caller notices -- the mutex acquisition and OS-level wait it wraps
  ;; dominate every measurable cost by orders of magnitude -- so keeping the
  ;; policy costs nothing real even where the compiler would have terminated
  ;; anyway, and it is retained on that basis.
  ;;
  ;; Why it is HERE and not a (DECLAIM (OPTIMIZE ...)) in src/package.lisp,
  ;; where it used to live: SBCL binds its compilation policy around both
  ;; COMPILE-FILE and LOAD, so an OPTIMIZE proclamation made by a file is
  ;; scoped to that file. Measured on SBCL 2.6.0: compile a.lisp containing
  ;; the declaim, LOAD a.fasl, then compile b.lisp -- b.lisp still compiles at
  ;; SPEED 1. The declaim therefore covered src/package.lisp and nothing else,
  ;; leaving the very file it was written for (src/scope.lisp) uncovered.
  ;; :AROUND-COMPILE is ASDF's per-file compile hook, so it covers every file
  ;; listed below, whatever order they are built in and whether or not any
  ;; earlier fasl was cached rather than recompiled.
  ;;
  ;; Why WITH-COMPILATION-UNIT's :POLICY and not PROCLAIM: :POLICY is
  ;; dynamically scoped (SB-EXT:RESTRICT-COMPILER-POLICY's own docstring
  ;; points at it), so it restores the caller's policy exactly on the way out
  ;; instead of leaving SPEED 0 proclaimed for everything a consumer compiles
  ;; after loading this system -- which, since ASDF builds dependencies first,
  ;; is the consumer's entire source tree.
  :around-compile (lambda (next)
                    (with-compilation-unit
                        (:policy '(optimize (speed 0) (safety 1) (space 1)
                                   (debug 1) (compilation-speed 1)))
                      (funcall next)))
  :components
  ((:file "package")
   (:file "conditions")
   (:file "primitives")
   (:file "timeout")
   (:file "promise")
   (:file "promise-combinators")
   (:file "promise-racing")
   (:file "channel")
   (:file "channel-waiters")
   (:file "select")
   (:file "executor-work-queue")
   (:file "executor")
   (:file "scope-state")
   (:file "scope-execution")
   (:file "scope")
   (:file "latch")
   (:file "stream")
   (:file "stream-terminal")
   (:file "stream-fan-out")
   (:file "stream-fan-in")
   (:file "stream-map-concurrent")
   (:file "stream-partition"))
  :in-order-to ((test-op (test-op "cl-concurrent-kit/test"))))

;;; The test system is `cl-concurrent-kit/test` (singular, slash-separated)
;;; with :pathname "t". It is NOT `cl-concurrent-kit-test`.
(asdf:defsystem "cl-concurrent-kit/test"
  :description "Test system for cl-concurrent-kit"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.6.0"
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
   (:file "timeout-test")
   (:file "promise-test")
   (:file "channel-test")
   (:file "select-test")
   (:file "executor-test")
   (:file "scope-test")
   (:file "latch-test")
   (:file "stream-test")
   (:file "stream-fan-out-test")
   (:file "stream-fan-in-test")
   (:file "stream-partition-test"))
  :perform (test-op (operation component)
             (declare (ignore operation component))
             (unless (funcall (symbol-function
                               (find-symbol "RUN-TESTS" "CL-CONCURRENT-KIT/TEST")))
               (error "cl-concurrent-kit test suite failed"))))
