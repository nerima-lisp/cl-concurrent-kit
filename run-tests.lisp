;;;; run-tests.lisp
;;;;
;;;; Bootstrap script: register this checkout's ASDF definition and run the
;;;; test system without scanning every inherited source registry tree.

(require :sb-cover)
(require :asdf)
(format t "tests: bootstrap~%")

(defun script-directory ()
  (make-pathname :name nil
                 :type nil
                 :defaults (or *load-truename*
                               *compile-file-truename*
                               (error "Unable to determine the script location"))))

(defun configure-local-source-registry (root) (let ((*package* (find-package :asdf))) (load (merge-pathnames #P"cl-concurrent-kit.asd" root))))

(let ((root (script-directory)))
  (format t "tests: system definition~%")
  (configure-local-source-registry root)
  (format t "tests: run~%")
  (asdf:test-system "cl-concurrent-kit")
  (format t "tests: complete~%")
  (uiop:quit 0))
