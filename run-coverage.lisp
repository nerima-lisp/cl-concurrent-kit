(progn
  #.(progn (require :asdf) (require :sb-cover) nil)

  ;; `checks.coverage-lcov` (this script) has been observed to intermittently
  ;; report far less than 100% expression coverage -- e.g. 57/921 -- on a
  ;; commit that is otherwise unchanged, while `checks.coverage` (SB-COVER's
  ;; plain in-memory :REPORT, built from the exact same instrumented test
  ;; run) passes at 100% every time. Reproduced locally across multiple
  ;; fresh, uncached x86_64-linux builds: some runs land on 100%, some land
  ;; on exactly 57/921, with no code change between them. A DIAG build
  ;; confirmed CL-CONCURRENT-KIT's sources are compiled exactly once (the
  ;; live coverage-hashtable file count is identical before and after
  ;; TEST-SYSTEM) -- so this is not a double-compile silently discarding
  ;; instrumentation. Since only the ENABLE-COVERAGE-LOGGING-dependent path
  ;; (this file) is affected and not plain :REPORT, suspect that logging
  ;; mechanism itself isn't safe under the concurrent, many-real-OS-threads
  ;; execution this test suite exercises by design (that's what it's
  ;; testing) -- i.e. an upstream SB-COVER limitation, not a bug in this
  ;; project's code. If this check fails, retry it before assuming a
  ;; regression; a hard 100% gate on it should be considered unreliable
  ;; until upstream addresses thread-safety in coverage logging.

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
    (sb-cover:enable-coverage-logging)
    (declaim (optimize (sb-cover:store-coverage-data 3)))
    (asdf:load-system "cl-concurrent-kit" :force t)
    (declaim (optimize (sb-cover:store-coverage-data 0)))
    ;; :FORCE T here too: cl-weave's own Nix package ships precompiled FASLs
    ;; alongside its sources with the same store-normalized timestamp as
    ;; those sources, so ASDF's ordinary freshness check can treat one as
    ;; already up to date and load it before the file defining its package
    ;; has run, signaling PACKAGE-DOES-NOT-EXIST. Forcing a from-source
    ;; recompile into our own isolated output cache sidesteps that.
    (asdf:load-system "cl-weave" :force t)
    (asdf:test-system "cl-concurrent-kit")
    (discard-ineligible-coverage-records root)
    (sb-cover:report (merge-pathnames "html/" output)
                      :if-matches (lambda (file)
                                    (source-file-p file root)))
    (sb-cover:lcov-report (merge-pathnames "lcov.info" output))
    (format t "Coverage reports written to ~A~%" output)
    (uiop:quit 0)))
