;;; reload.el --- Batch checks for loading canvas-minimap over itself -*- lexical-binding: t; -*-

;; Like tests/guards.el these run headless, and need no canvas:
;;
;;     emacs -batch -Q -l tests/reload.el -f ert-run-tests-batch-and-exit
;;
;; Working on the package means loading the file again over a running
;; copy, often with a slot added to the map's state.  Loading a file
;; inlines each accessor a function calls as a fixed slot number, taken
;; from the struct as it stands when that function is read.  A function
;; read before the new struct definition keeps the old numbers.

;;; Code:

(require 'ert)

(defvar canvas-minimap-test--source
  (expand-file-name "../canvas-minimap.el"
                    (file-name-directory (or load-file-name buffer-file-name))))

(load canvas-minimap-test--source nil t)

(defun canvas-minimap-test--load-with-extra-slot ()
  "Load the source again with one more slot at the head of the state."
  (let ((copy (make-temp-file "canvas-minimap-reload" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file copy
            (insert-file-contents canvas-minimap-test--source)
            (goto-char (point-min))
            (re-search-forward "^  image ")
            (beginning-of-line)
            (insert "  reload-test-slot\n"))
          (load copy nil t))
      (delete-file copy))))

(ert-deftest canvas-minimap-reload-keeps-fringe-colours-readable ()
  "GIVEN the package loaded, then loaded again with a slot added at the
head of the map's state, which moves every slot after it
WHEN a fringe mark's colour is looked up for a state the new definition
built
THEN the colour comes back, and is kept in that state's own cache."
  (unwind-protect
      (progn
        (canvas-minimap-test--load-with-extra-slot)
        ;; By quoted name through `funcall': this test was read before
        ;; the reload, and a direct call here -- or a `funcall' of #'NAME,
        ;; which reading turns into one -- would carry the old slot
        ;; numbers just as the code under test can.
        (let ((st (funcall 'canvas-minimap--state-create
                           :gutter-colors (make-hash-table :test 'equal)
                           :bg '(0 0 0) :fg '(255 255 255))))
          (should (integerp (canvas-minimap--fringe-pix st 'default)))
          (should (gethash 'default
                           (funcall 'canvas-minimap--state-gutter-colors st)))))
    (load canvas-minimap-test--source nil t)))

;;; reload.el ends here
