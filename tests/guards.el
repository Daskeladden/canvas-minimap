;;; guards.el --- Batch checks for canvas-minimap input guards -*- lexical-binding: t; -*-

;; Unlike tests/battery.el, which draws on a real canvas, these run
;; headless:
;;
;;     emacs -batch -Q -l tests/guards.el -f ert-run-tests-batch-and-exit
;;
;; They cover the guard that stops the background poll from holding the
;; command loop while forced font-lock runs -- the failure that let a
;; single buffer's pathological font-lock matcher peg the whole daemon.

;;; Code:

(require 'ert)
(require 'cl-lib)

(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  ;; The source, not a compiled file beside it that may be older.
  (load (expand-file-name "../canvas-minimap.el" here) nil t))

(ert-deftest canvas-minimap-yield-runs-thunk-when-no-input ()
  "GIVEN no pending input
WHEN the guard runs a thunk
THEN it returns the thunk's value rather than the default."
  (should (equal 42 (canvas-minimap--yield-to-input 'default (lambda () 42)))))

(ert-deftest canvas-minimap-yield-skips-thunk-when-input-pending ()
  "GIVEN input already pending
WHEN the guard would run a thunk
THEN the thunk never runs and the default comes back -- a runaway
fontification cannot even start while the user is typing."
  (cl-letf (((symbol-function 'input-pending-p) (lambda (&rest _) t)))
    (should (eq 'default
                (canvas-minimap--yield-to-input
                 'default
                 (lambda () (error "thunk ran despite pending input")))))))

(ert-deftest canvas-minimap-fontify-skips-when-input-pending ()
  "GIVEN input pending and an unfontified region
WHEN `canvas-minimap--fontify' is asked to force faces
THEN it does not call `font-lock-ensure': the keystroke wins, and a
looping matcher never gets to run."
  (with-temp-buffer
    (insert "some text\n")
    (setq-local font-lock-mode t)
    (let ((called nil))
      (cl-letf (((symbol-function 'input-pending-p) (lambda (&rest _) t))
                ((symbol-function 'font-lock-ensure)
                 (lambda (&rest _) (setq called t))))
        (canvas-minimap--fontify (point-min) (point-max))
        (should-not called)))))

(ert-deftest canvas-minimap-fontify-forces-when-idle ()
  "GIVEN no pending input and an unfontified region
WHEN `canvas-minimap--fontify' runs
THEN it calls `font-lock-ensure' so faces are ready to read."
  (with-temp-buffer
    (insert "some text\n")
    (setq-local font-lock-mode t)
    (let ((called nil))
      (cl-letf (((symbol-function 'input-pending-p) (lambda (&rest _) nil))
                ((symbol-function 'font-lock-ensure)
                 (lambda (&rest _) (setq called t))))
        (canvas-minimap--fontify (point-min) (point-max))
        (should called)))))

(provide 'canvas-minimap-guards)
;;; guards.el ends here

(ert-deftest canvas-minimap-image-thumb-believes-a-thumbnail-function ()
  "GIVEN a thumbnail function that answers for an image
WHEN the map asks for that image's pixels
THEN it gets that answer and never turns to the image's file."
  (let ((canvas-minimap-thumbnail-functions
         (list (lambda (_img w h _bg) (make-vector (* w h) #xFF123456)))))
    (cl-letf (((symbol-function 'canvas-minimap--thumb)
               (lambda (&rest _) (error "the file was read"))))
      (let ((pixels (canvas-minimap--image-thumb '(image :type canvas :id x) 3 2 0)))
        (should (= (length pixels) 6))
        (should (= (aref pixels 0) #xFF123456))))))

(ert-deftest canvas-minimap-image-thumb-falls-back-to-the-file ()
  "GIVEN no thumbnail function answers
WHEN the map asks for an image's pixels
THEN the image's file is downsampled as before."
  (let ((canvas-minimap-thumbnail-functions (list (lambda (&rest _) nil))))
    (cl-letf (((symbol-function 'canvas-minimap--thumb)
               (lambda (file w h bg) (list 'file file w h bg))))
      (should (equal (canvas-minimap--image-thumb '(image :type png :file "/tmp/x.png") 3 2 7)
                     '(file "/tmp/x.png" 3 2 7))))))

(ert-deftest canvas-minimap-image-thumb-rejects-a-wrong-sized-answer ()
  "GIVEN a thumbnail function that answers with too few pixels
WHEN the map asks for an image's pixels
THEN that is an error rather than a torn picture."
  (let ((canvas-minimap-thumbnail-functions
         (list (lambda (&rest _) (make-vector 2 0)))))
    (should-error (canvas-minimap--image-thumb '(image :type canvas :id x) 3 2 0))))

(ert-deftest canvas-minimap-picture-changed-marks-the-buffer-dirty ()
  "GIVEN a buffer with nothing marked for redrawing
WHEN it says its picture changed
THEN its lines are marked dirty from the first."
  (with-temp-buffer
    (insert "#")
    (should-not canvas-minimap--dirty)
    (canvas-minimap-picture-changed (current-buffer))
    (should (equal canvas-minimap--dirty '(1 . 1)))))

(ert-deftest canvas-minimap-fraction-says-where-a-point-falls ()
  "GIVEN a span from 10 to 20
WHEN points inside, before and past it are placed
THEN they read as 0 to 1, clamped, AND an empty span reads as 0."
  (should (= (canvas-minimap--fraction 15 10 20) 0.5))
  (should (= (canvas-minimap--fraction 5 10 20) 0.0))
  (should (= (canvas-minimap--fraction 25 10 20) 1.0))
  (should (= (canvas-minimap--fraction 15 10 10) 0.0)))

(defvar canvas-minimap-test--taken nil "What the picture-click hook was handed.")
(defvar canvas-minimap-test--scrolled nil "Where the source was scrolled to.")

(ert-deftest canvas-minimap-scrub-hands-a-picture-to-its-owner ()
  "GIVEN a click that lands on a picture with an owner that takes it,
and one that lands on text
WHEN each is scrubbed
THEN the owner gets the picture's fractions, the source is left alone
and the map is drawn again at once, so a drag shows as it goes,
AND the text click scrolls the source as before."
  (let ((canvas-minimap-test--taken nil) (canvas-minimap-test--scrolled nil)
        (updated 0)
        (canvas-minimap-picture-click-functions
         (list (lambda (img fx fy) (setq canvas-minimap-test--taken (list img fx fy)) t))))
    (cl-letf (((symbol-function 'canvas-minimap--picture-at)
               (lambda (_st x y) (and (= x 20) (list 'the-image 0.25 (/ y 100.0)))))
              ((symbol-function 'canvas-minimap--goto-y)
               (lambda (_st y) (setq canvas-minimap-test--scrolled y)))
              ((symbol-function 'canvas-minimap--update)
               (lambda () (setq updated (1+ updated)))))
      (let ((st (canvas-minimap--state-create :scale 2)))
        (canvas-minimap--scrub st '(10 . 25))
        (should (equal canvas-minimap-test--taken '(the-image 0.25 0.5)))
        (should-not canvas-minimap-test--scrolled)
        (should (= updated 1))
        (canvas-minimap--scrub st '(30 . 7))
        (should (= canvas-minimap-test--scrolled 7))
        (should (= updated 1))))))

(ert-deftest canvas-minimap-markdown-after-string-image-layout ()
  "An appended Markdown image preserves the link row and image height."
  (with-temp-buffer
    (insert "![preview](x.png)\nnext line\n")
    (goto-char (point-min))
    (let* ((end (line-end-position))
           (img '(image :type png :file "/tmp/x.png"))
           (ov (make-overlay (1- end) end))
           (st (canvas-minimap--state-create :rows 100)))
      (overlay-put ov 'after-string
                   (concat "\n" (propertize " " 'display img)))
      (cl-letf (((symbol-function 'image-size) (lambda (&rest _) '(100 . 60)))
                ((symbol-function 'frame-char-height) (lambda (&rest _) 10)))
        (should (equal (canvas-minimap--line-image st 1 end nil)
                       (list img 7 1)))
        ;; View mode hides link markup while keeping its appended image.
        (put-text-property (1- end) end 'invisible t)
        (should (equal (canvas-minimap--line-image st 1 end nil)
                       (list img 7 1)))
        ;; A window-specific overlay must not leak into another window.
        (overlay-put ov 'window 'another-window)
        (should-not (canvas-minimap--line-image st 1 end nil))
        (overlay-put ov 'window nil)
        ;; Hidden images and inline icons must not become standalone pictures.
        (overlay-put ov 'invisible t)
        (should-not (canvas-minimap--line-image st 1 end nil))
        (overlay-put ov 'invisible nil)
        (overlay-put ov 'after-string (propertize " " 'display img))
        (should-not (canvas-minimap--line-image st 1 end nil))))))

(ert-deftest canvas-minimap-after-string-changes-invalidate ()
  "Adding, replacing and removing an appended image invalidates its line."
  (with-temp-buffer
    (insert "image link\n")
    (let* ((ov (make-overlay 1 3))
           (st (canvas-minimap--state-create
                :slice-beg (copy-marker (point-min))
                :slice-end (copy-marker (point-max))
                :overlays (make-hash-table :test 'eq)))
           (invalidated nil))
      (cl-letf (((symbol-function 'canvas-minimap--invalidate-span)
                 (lambda (&rest _) (setq invalidated t))))
        (dolist (file '("a.png" "b.png" nil))
          (setq invalidated nil)
          (overlay-put ov 'after-string
                       (and file (concat "\n" (propertize " " 'display
                                              `(image :type png :file ,file)))))
          (should (canvas-minimap--scan-overlays st (current-buffer) nil))
          (should invalidated)
          (should-not (canvas-minimap--scan-overlays st (current-buffer) nil)))))))
