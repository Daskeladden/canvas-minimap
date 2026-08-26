;;; headers.el --- Batch checks for the canvas-minimap package headers -*- lexical-binding: t; -*-

;; Like tests/guards.el these run headless, and need no canvas:
;;
;;     emacs -batch -Q -L . -l tests/headers.el -f ert-run-tests-batch-and-exit
;;
;; They cover what a stranger installing the package meets first: the
;; headers package.el reads, and the licence file the README points at.

;;; Code:

(require 'ert)
(require 'lisp-mnt)
(require 'package)

(defun canvas-minimap-test--library ()
  "The source file of the canvas-minimap library."
  (let ((file (locate-library "canvas-minimap.el")))
    (should file)
    file))

(ert-deftest canvas-minimap-package-headers-describe-the-package ()
  ;; GIVEN the library as it is published
  ;; WHEN package.el reads its headers
  ;; THEN it finds the name, a version, a one-line summary and a URL
  (with-temp-buffer
    (insert-file-contents (canvas-minimap-test--library))
    (let ((info (package-buffer-info)))
      (should (equal (package-desc-name info) 'canvas-minimap))
      (should (version-list-<= '(0 1) (package-desc-version info)))
      (should-not (equal (package-desc-summary info) "No description available."))
      (should (string-prefix-p "https://" (cdr (assq :url (package-desc-extras info))))))))

(ert-deftest canvas-minimap-package-requires-an-emacs-that-can-run-it ()
  ;; GIVEN the library, which needs a canvas and the transient menus
  ;; WHEN its requirements are read
  ;; THEN transient is declared, AND the Emacs it asks for is one this
  ;;      very Emacs satisfies -- a requirement no released Emacs meets
  ;;      would keep package.el from ever installing it
  (with-temp-buffer
    (insert-file-contents (canvas-minimap-test--library))
    (let* ((reqs (package-desc-reqs (package-buffer-info)))
           (wanted (cadr (assq 'emacs reqs))))
      (should (version-list-<= '(32) wanted))
      (should (version-list-<= wanted (version-to-list emacs-version)))
      (should (assq 'transient reqs)))))

(ert-deftest canvas-minimap-package-names-its-author-and-licence ()
  ;; GIVEN the library, published under the GPL alongside shipit and the
  ;;       other canvas packages
  ;; WHEN its headers and leading comments are read
  ;; THEN it names an author, holds the copyright the way they all do,
  ;;      AND carries a Commentary section and the licence notice
  (with-temp-buffer
    (insert-file-contents (canvas-minimap-test--library))
    (should (string-match-p "[^ ]" (or (lm-header "author") "")))
    (should (save-excursion
              (goto-char (point-min))
              (re-search-forward "^;; Copyright (C) [0-9-]+ canvas-minimap contributors$"
                                 nil t)))
    (should (lm-commentary-start))
    (should (save-excursion (re-search-forward "GNU General Public License" nil t)))))

(ert-deftest canvas-minimap-licence-file-is-the-whole-gpl ()
  ;; GIVEN a README that says GPL-3.0-or-later and points at LICENSE
  ;; WHEN that file is read
  ;; THEN it is the licence itself, not a summary pointing elsewhere
  (let ((license (expand-file-name
                  "LICENSE" (file-name-directory (canvas-minimap-test--library)))))
    (should (file-readable-p license))
    (with-temp-buffer
      (insert-file-contents license)
      (should (save-excursion (re-search-forward "TERMS AND CONDITIONS" nil t)))
      (should (save-excursion (re-search-forward "Version 3, 29 June 2007" nil t))))))

(ert-deftest canvas-minimap-readme-documents-the-picture-protocol ()
  ;; GIVEN three symbols another package hooks into -- canvas-diagram
  ;;       draws its diagram into the map through them
  ;; WHEN the README a stranger reads is searched for them
  ;; THEN each is named there: a public extension point nobody can find
  ;;      is one nobody can use
  (let ((readme (expand-file-name
                 "README.md" (file-name-directory (canvas-minimap-test--library)))))
    (should (file-readable-p readme))
    (with-temp-buffer
      (insert-file-contents readme)
      (dolist (symbol '("canvas-minimap-thumbnail-functions"
                        "canvas-minimap-picture-click-functions"
                        "canvas-minimap-picture-changed"))
        (goto-char (point-min))
        (should (search-forward symbol nil t))))))

(provide 'headers)
;;; headers.el ends here
