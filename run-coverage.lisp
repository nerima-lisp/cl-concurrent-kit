(progn
  #.(progn (require :asdf) (require :sb-cover) nil)

  ;; `checks.coverage-lcov` (this script) has been observed to report far
  ;; less than 100% expression coverage -- e.g. 57/921, or 85/2306 -- on a
  ;; commit that is otherwise unchanged, while `checks.coverage` (SB-COVER's
  ;; plain in-memory :REPORT, built from the exact same instrumented test
  ;; run) passes at 100% every time. Two distinct causes have been found so
  ;; far, and this script now avoids the second:
  ;;
  ;; 1. On a small enough source tree, reproduced across multiple fresh,
  ;;    uncached x86_64-linux builds landing on 100% some runs and on
  ;;    exactly 57/921 on others, with no code change between them, and a
  ;;    DIAG build showing CL-CONCURRENT-KIT's sources compiled exactly
  ;;    once either way (the live coverage-hashtable file count identical
  ;;    before and after TEST-SYSTEM) -- not a double-compile silently
  ;;    discarding instrumentation. Only the ENABLE-COVERAGE-LOGGING-
  ;;    dependent path (this file) was affected, not plain :REPORT, so
  ;;    suspect ENABLE-COVERAGE-LOGGING's own recording mechanism isn't
  ;;    safe under the concurrent, many-real-OS-threads execution this
  ;;    test suite exercises by design -- an upstream SB-COVER limitation.
  ;;
  ;; 2. On a larger source tree (confirmed deterministic, not flaky, via a
  ;;    DIAG build: the exact same 85/2306 result across three independent
  ;;    fresh builds, local and via `nix build`), every file after
  ;;    PACKAGE.LISP compiled exactly *twice*. Each top-level
  ;;    ASDF:LOAD-SYSTEM/ASDF:TEST-SYSTEM call opens its own fresh ASDF
  ;;    session (ASDF/SESSION:WITH-ASDF-SESSION) unless one is already
  ;;    active, and a session is what makes ASDF remember "already
  ;;    performed LOAD-OP on this component" so a later call does not redo
  ;;    it -- this script used to make three separate top-level calls
  ;;    (LOAD-SYSTEM, LOAD-SYSTEM, TEST-SYSTEM), so TEST-SYSTEM's own
  ;;    transitive LOAD-OP on "cl-concurrent-kit" (a dependency of
  ;;    "cl-concurrent-kit/test") silently recompiled every file a second
  ;;    time, with STORE-COVERAGE-DATA already dropped back to 0 by then,
  ;;    discarding their instrumentation without changing which code
  ;;    actually ran. Fixed below by making a single top-level call.
  ;;
  ;; If this check fails and a DIAG build (temporarily wrap COMPILE-FILE,
  ;; as in the git history of this file, to log every call) shows each
  ;; source file compiled exactly once, suspect cause 1 and retry before
  ;; assuming a regression -- a hard 100% gate is unreliable for that
  ;; reason until upstream addresses thread-safety in coverage logging.
  ;; If it instead shows a file compiled more than once, that is cause 2
  ;; (or a new variant of it) recurring, and retrying will not help.

  (defun script-directory ()
    (make-pathname :name nil
                   :type nil
                   :defaults (or *load-truename*
                                 *compile-file-truename*
                                 (error "Unable to determine the script location"))))

  (defun source-root ()
    "This project's own root, honoring CL_CONCURRENT_KIT_SOURCE_ROOT when set.
Necessary because this script itself may run from a location that is not the
project root -- e.g. copied into the Nix store as its own derivation by
flake.nix's coverage check/app, which passes the real checkout separately
rather than relying on this script's own store path."
    (uiop:ensure-directory-pathname
     (let ((override (uiop:getenv "CL_CONCURRENT_KIT_SOURCE_ROOT")))
       (if override
           (uiop:parse-native-namestring override)
           (script-directory)))))

  (defun configure-local-source-registry (root)
    (asdf:initialize-source-registry
     `(:source-registry
       (:tree ,root)
       :inherit-configuration)))

  (defun output-directory ()
    (let ((argument (first (uiop:command-line-arguments))))
      (ensure-directories-exist
       (if argument
           (uiop:ensure-directory-pathname (uiop:parse-native-namestring argument))
           (merge-pathnames "coverage/" (uiop:getcwd))))))

  (defun configure-isolated-output-cache (directory)
    (let ((cache (merge-pathnames "asdf-cache/" directory)))
      (ensure-directories-exist cache)
      (asdf:initialize-output-translations
       `(:output-translations
         (t ,cache)
         :ignore-inherited-configuration))))

  (defun source-file-p (file root)
    "True for FILE under ROOT's src/ directory -- this project's own sources,
never cl-weave's or the test suite's -- so coverage instrumentation on a
dependency or on the tests themselves never dilutes this project's own
number."
    (uiop:subpathp (uiop:parse-native-namestring file) (merge-pathnames "src/" root)))

  (defun discard-ineligible-coverage-records (root)
    (let ((table (sb-cover::code-coverage-hashtable))
          (discarded-files nil))
      (maphash (lambda (file coverage)
                 (declare (ignore coverage))
                 ;; PACKAGE.LISP is declarations only (verify-lcov.pl's own
                 ;; comment). It used to emit no DA records at all; now that
                 ;; it is large enough for SB-COVER to record per-line DA
                 ;; entries, every one of them is 0-hit, which would leave it
                 ;; with zero *countable* DA rows and trip verify-lcov.pl's
                 ;; "every SF record has at least one real DA row" check.
                 ;; Drop it here instead of trying to special-case that.
                 (unless (and (source-file-p file root)
                              (string/= (file-namestring file) "package.lisp"))
                   (push file discarded-files)))
               table)
      (dolist (file discarded-files)
        (remhash file table))))

  (let* ((root (source-root))
         (output (output-directory)))
    (configure-local-source-registry root)
    (configure-isolated-output-cache output)
    ;; Without this, compiled FASLs carry only source PATHS, not the
    ;; byte-offset locations/line lengths LCOV-REPORT needs to compute
    ;; per-line state without re-reading source -- SB-COVER:REPORT's HTML
    ;; output re-reads the file directly and works either way, but
    ;; LCOV-REPORT does not and signals a TYPE-ERROR (NIL is not of type
    ;; VECTOR) without it.
    ;; A single top-level ASDF:TEST-SYSTEM call below, not the three
    ;; separate LOAD-SYSTEM/LOAD-SYSTEM/TEST-SYSTEM calls this used to
    ;; make: each top-level call opens its own fresh ASDF session
    ;; (ASDF/SESSION:WITH-ASDF-SESSION) unless one is already active, and a
    ;; session is what makes ASDF remember "already performed LOAD-OP on
    ;; this component" so a later call does not redo it -- confirmed by a
    ;; DIAG build: three separate calls, each opening its own session,
    ;; silently recompiled every file a second time via TEST-SYSTEM's own
    ;; transitive LOAD-OP on "cl-concurrent-kit" (a dependency of
    ;; "cl-concurrent-kit/test") -- discarding their coverage
    ;; instrumentation, once STORE-COVERAGE-DATA had already dropped back
    ;; to 0, without changing which code actually ran. Sharing one session
    ;; across explicit LOAD-SYSTEM calls turned out not to help either:
    ;; ASDF forbids a nested call's :FORCE from disagreeing with the
    ;; session's first (toplevel) call, in a way that no single :FORCE
    ;; value passed identically to all three calls actually satisfies.
    ;; A single call sidesteps the whole problem: every component is
    ;; visited exactly once by construction, so this :AROUND method is the
    ;; only mechanism left needed to instrument CL-CONCURRENT-KIT's own
    ;; files without also instrumenting CL-WEAVE's. Defined -- and, being a
    ;; DEFMETHOD, compiled -- before ENABLE-COVERAGE-LOGGING turns on
    ;; coverage's own breakpoint-based instrumentation below, so compiling
    ;; this method is never itself subject to it.
    (let ((cl-concurrent-kit (asdf:find-system "cl-concurrent-kit")))
      (defmethod asdf:perform :around
          ((operation asdf:compile-op) (component asdf:cl-source-file))
        (if (eq (asdf:component-system component) cl-concurrent-kit)
            (progn
              (declaim (optimize (sb-cover:store-coverage-data 3)))
              (unwind-protect (call-next-method)
                (declaim (optimize (sb-cover:store-coverage-data 0)))))
            (call-next-method))))
    (sb-cover:enable-coverage-logging)
    (declaim (optimize (sb-cover:store-coverage-data 0)))
    ;; :FORCE T: cl-weave's own Nix package ships precompiled FASLs
    ;; alongside its sources with the same store-normalized timestamp as
    ;; those sources, so ASDF's ordinary freshness check can treat one as
    ;; already up to date and load it before the file defining its package
    ;; has run, signaling PACKAGE-DOES-NOT-EXIST. Forcing a from-source
    ;; recompile into our own isolated output cache sidesteps that -- for
    ;; CL-CONCURRENT-KIT too, so every one of its own forms is freshly
    ;; compiled under the :AROUND method above rather than possibly reusing
    ;; an earlier, differently-instrumented FASL from this same process.
    (asdf:test-system "cl-concurrent-kit" :force t)
    (discard-ineligible-coverage-records root)
    (sb-cover:report (merge-pathnames "html/" output)
                      :if-matches (lambda (file)
                                    (source-file-p file root)))
    (sb-cover:lcov-report (merge-pathnames "lcov.info" output))
    (format t "Coverage reports written to ~A~%" output)
    (uiop:quit 0)))
