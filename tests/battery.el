;;; battery.el --- Checks for canvas-minimap  -*- lexical-binding: t; -*-

;; Run it from a terminal, on a graphical display:
;;
;;     emacs -Q -rv --iconic -l tests/battery.el
;;
;; The flags keep the frame iconified and dark, so a run does not take
;; over the screen; leave them off to watch it.
;;
;; Results are written to standard error as each check finishes, and the
;; exit status is how many failed.  The map draws on a canvas in a real
;; window, so there is nothing here that batch mode can run.
;;
;; The checks are the ones worth keeping: that an incremental redraw
;; ends up with the same pixels as a fresh one, that a settled map
;; uploads nothing, and that the parts which read the buffer -- folding,
;; narrowing, images, completion candidates -- still land on the right
;; rows.
;;
;; Every check here has been run against a copy of the package with the
;; thing it names deliberately broken, and fails there.  A check that
;; passes either way is not worth the second it costs.
;;
;; Each scenario says what it proves in GIVEN/WHEN/THEN comments.  A
;; scenario often spans several steps, since a glide has to be waited
;; out; the block sits with the phase it describes.

;;; Code:

(require 'cl-lib)

(defvar battery-root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))
(add-to-list 'load-path battery-root)
;; The source, not a compiled file beside it that may be older than it.
(load (expand-file-name "canvas-minimap.el" battery-root) nil t)

(defvar battery-failed 0)

(defun battery-say (fmt &rest args)
  (princ (concat (apply #'format fmt args) "\n") #'external-debugging-output))

(defun battery-check (name ok &optional detail)
  (unless ok (setq battery-failed (1+ battery-failed)))
  (battery-say "%-40s %s%s" name (if ok "PASS" "FAIL")
               (if detail (format "   %s" detail) "")))

(defun battery-skip (name why)
  (battery-say "%-40s SKIP   %s" name why))

(defun battery-buffers-made (thunk)
  "How many new buffers a call to THUNK creates."
  (let ((made 0))
    (advice-add 'generate-new-buffer :before
                (lambda (&rest _) (setq made (1+ made)))
                '((name . battery-buffer-count)))
    (unwind-protect (funcall thunk)
      (advice-remove 'generate-new-buffer 'battery-buffer-count))
    made))

;;;; Getting at the map

(defun battery-state ()
  "The state of the frame's minimap."
  (or (gethash (canvas-minimap--frame-window (selected-frame)) canvas-minimap--states)
      (let (found)
        (maphash (lambda (_ st) (setq found st)) canvas-minimap--states)
        found)))

(defun battery-cookies (st n)
  "The buffer lines ST draws in its first N slots."
  (let (lines)
    (dotimes (i n) (push (aref (canvas-minimap--state-cookies st) i) lines))
    (nreverse lines)))

(defun battery-differs (a b)
  "How many pixels of A and B are not the same."
  (let ((n 0))
    (dotimes (i (length a))
      (unless (eql (aref a i) (aref b i)) (setq n (1+ n))))
    n))

(defun battery-settle (&optional seconds)
  "Let a glide finish, waiting up to SECONDS for it."
  (let ((left (or seconds 3.0)))
    (while (and canvas-minimap--glide-timer (> left 0))
      (sit-for 0.05)
      (setq left (- left 0.05))))
  (canvas-minimap--update))

(defun battery-drawn (thunk)
  "How many line slots calling THUNK rasterizes."
  (let ((n 0)
        (orig (symbol-function 'canvas-minimap--render-slot)))
    (cl-letf (((symbol-function 'canvas-minimap--render-slot)
               (lambda (&rest args) (setq n (1+ n)) (apply orig args))))
      (funcall thunk))
    n))

(defun battery-slot-pixels (st slot)
  "Copy of the canvas rows ST draws SLOT on."
  (let ((w (canvas-minimap--state-width st))
        (y (canvas-minimap--slot-y st slot))
        (lh (canvas-minimap--state-lh st)))
    (substring (canvas-minimap--state-data st) (* y w) (* (+ y lh) w))))

(defun battery-ink (st slot from)
  "Pixels ST draws on SLOT, past FROM columns of text, that are not its ground.
The ground is whichever colour most of the row is, rather than the
map\'s background: the viewport band tints whole rows, and what is
drawn on a row is what stands out from the rest of it."
  (let* ((w (canvas-minimap--state-width st))
         (lh (canvas-minimap--state-lh st))
         (x0 (+ (canvas-minimap--state-text-x0 st) from))
         (x1 (canvas-minimap--state-text-x1 st))
         (row (battery-slot-pixels st slot))
         (seen (make-hash-table :test 'eql))
         (ground nil)
         (most 0)
         (total 0))
    (dotimes (dy lh)
      (let ((x x0))
        (while (< x x1)
          (let* ((px (aref row (+ (* dy w) x)))
                 (n (1+ (gethash px seen 0))))
            (puthash px n seen)
            (when (> n most) (setq most n ground px)))
          (setq total (1+ total))
          (setq x (1+ x)))))
    (ignore ground)
    (- total most)))

(defun battery-ink-end (st slot)
  "Rightmost column of SLOT that is not its ground, counted from the text edge."
  (let* ((w (canvas-minimap--state-width st))
         (lh (canvas-minimap--state-lh st))
         (x0 (canvas-minimap--state-text-x0 st))
         (x1 (canvas-minimap--state-text-x1 st))
         (row (battery-slot-pixels st slot))
         (seen (make-hash-table :test 'eql))
         (ground nil)
         (most 0)
         (end nil))
    (dotimes (dy lh)
      (let ((x x0))
        (while (< x x1)
          (let* ((px (aref row (+ (* dy w) x)))
                 (n (1+ (gethash px seen 0))))
            (puthash px n seen)
            (when (> n most) (setq most n ground px)))
          (setq x (1+ x)))))
    (dotimes (dy lh)
      (let ((x x0))
        (while (< x x1)
          (unless (eql (aref row (+ (* dy w) x)) ground)
            (setq end (max (or end 0) (- x x0))))
          (setq x (1+ x)))))
    end))

(defun battery-pixel (st slot dy dx)
  "The pixel ST draws DY rows down and DX text columns into SLOT."
  (let ((w (canvas-minimap--state-width st))
        (x0 (canvas-minimap--state-text-x0 st)))
    (aref (battery-slot-pixels st slot) (+ (* dy w) x0 dx))))

(defun battery-slot-of (st line)
  "The row ST draws buffer LINE on, or nil."
  (let (found)
    (dotimes (i (canvas-minimap--state-rows st))
      (when (and (not found) (eql (aref (canvas-minimap--state-cookies st) i) line))
        (setq found i)))
    found))

(defun battery-deco-slots (st bit)
  "Slots of ST carrying decoration BIT."
  (let ((deco (canvas-minimap--state-deco st))
        slots)
    (dotimes (i (canvas-minimap--state-rows st))
      (unless (zerop (logand (aref deco i) bit)) (push i slots)))
    (nreverse slots)))

(defvar battery-probed nil)
(defvar battery-probe-fn #'ignore)

(defun battery-probe ()
  "Record what `battery-probe-with' asked for, latest first.
Bound to a key, so a keyboard macro can look at a prompt from inside it,
while the prompt is still up."
  (interactive)
  (push (funcall battery-probe-fn) battery-probed))

(defun battery-probe-with (fn)
  "Have each `battery-probe' from now on record what FN returns."
  (setq battery-probed nil battery-probe-fn fn))

(global-set-key [f9] #'battery-probe)

(defun battery-menu-line (start)
  "The menu entry beginning with START: its text, and whether it is dimmed."
  (with-current-buffer transient--buffer-name
    (save-excursion
      (goto-char (point-min))
      (search-forward (concat " " start) nil t)
      ;; An entry ends where the next column begins, three spaces on.
      (let* ((from (match-beginning 0))
             (to (or (save-excursion (search-forward "   " (line-end-position) t))
                     (line-end-position)))
             (dim (cl-loop for pos from from below to
                           thereis (memq 'transient-inapt-suffix
                                         (ensure-list (get-text-property pos 'face))))))
        (cons (buffer-substring-no-properties from to) (and dim t))))))

(defun battery-jump (line)
  "Put LINE in the middle of the source window and let the map catch up."
  (with-selected-window (frame-selected-window)
    (goto-char (point-min))
    (forward-line (1- line))
    (recenter))
  (canvas-minimap--update))

(defvar battery-width nil)
(defvar battery-rows nil)
(defvar battery-left-behind nil)
(defvar battery-picture-slot nil)
(defvar battery-picture-line nil)
(defvar battery-band-row nil)
(defvar battery-picture-row nil)
(defvar battery-pillow
  (eq 0 (ignore-errors (call-process "python3" nil nil nil "-c" "import PIL")))
  "Whether the thumbnails can be made here at all.")
(defvar battery-uploads 0)
(advice-add 'canvas-refresh :before
            (lambda (&rest _) (setq battery-uploads (1+ battery-uploads))))

;;;; Steps
;;
;; A glide runs on a timer, so the checks are a queue of thunks with a
;; wait in front of each rather than one straight line of code.

(defvar battery-steps nil)

(defun battery-run ()
  (if battery-steps
      (let ((step (pop battery-steps)))
        (run-at-time (car step) nil
                     (lambda ()
                       (condition-case err (funcall (cdr step))
                         ((quit error)
                          (battery-check "step" nil (format "%S" err))))
                       (battery-run))))
    (battery-say "%d failed" battery-failed)
    (kill-emacs (min battery-failed 100))))

(defmacro battery-step (delay &rest body)
  (declare (indent 1))
  `(push (cons ,delay (lambda () ,@body)) battery-steps))

;;;; The buffers under test

(defvar battery-src (get-buffer-create "src.el"))
(defvar battery-org (get-buffer-create "fold.org"))

(with-current-buffer battery-src
  (emacs-lisp-mode)
  (dotimes (i 1200) (insert (format ";; line %d  (defun f%d () %d)\n" i i i))))

(with-current-buffer battery-org
  (org-mode)
  (dotimes (i 4)
    (insert (format "* heading %d\n" i))
    (dotimes (j 5) (insert (format "  body %d of %d\n" j i))))
  (goto-char (point-min)))

;;;; Checks that need no map

;; GIVEN the display specs a fringe indicator arrives in, plain and
;; nested, and some display properties that are not indicators at all
;; THEN the face is read out of the indicators and nothing else is
;; taken for one
(battery-check
 "fringe specs name their face"
 (and (eq 'success (canvas-minimap--fringe-face '(left-fringe filled-square success)))
      (eq 'success (canvas-minimap--fringe-face '((left-fringe filled-square success))))
      (eq 'fringe (canvas-minimap--fringe-face '(right-fringe filled-square)))
      (null (canvas-minimap--fringe-face '(space :width 2)))
      (null (canvas-minimap--fringe-face "an ordinary string"))))

;; GIVEN two colours
;; THEN blending none of the second gives the first, all of it gives
;; the second, and half of it lands between them
(battery-check
 "blending ends at both colours"
 (let ((black '(0 0 0)) (white '(255 255 255)))
   (and (equal black (canvas-minimap--blend black white 0.0))
        (equal white (canvas-minimap--blend black white 1.0))
        (let ((mid (car (canvas-minimap--blend black white 0.5))))
          (and (< 120 mid) (< mid 136))))))

;; GIVEN the glyph table the package ships
;; THEN a denser character covers more of its cell than a sparser one
(battery-check
 "a denser glyph inks more of its cell"
 (let ((ink (lambda (ch)
              (let ((cell (canvas-minimap--downsample
                           (canvas-minimap--glyph-cell
                            ch canvas-minimap--glyph-coverage)
                           4 4))
                    (sum 0))
                (dotimes (i 16) (setq sum (+ sum (aref cell i))))
                sum))))
   (> (funcall ink ?M) (funcall ink ?.) (funcall ink ?\s))))

;; GIVEN a coverage table on disk that has been read once already
;; WHEN its cache entry is dropped and it is read again
;; THEN no new buffer is made for it -- the reader reuses a work
;; buffer (issue #1)
(battery-check
 "the coverage reader reuses a buffer"
 (let* ((canvas-minimap-glyph-directory (make-temp-file "battery-glyphs" t))
        (family "Battery Reuse Font")
        (table (make-string (canvas-minimap--coverage-length) ?5)))
   (unwind-protect
       (progn
         (with-temp-file (canvas-minimap--glyph-file family)
           (insert table))
         (canvas-minimap--active-coverage family)
         (remhash family canvas-minimap--glyph-tables)
         (let* (read
                (made (battery-buffers-made
                       (lambda ()
                         (setq read (canvas-minimap--active-coverage family))))))
           (and (equal table read) (= 0 made))))
     (remhash family canvas-minimap--glyph-tables)
     (delete-directory canvas-minimap-glyph-directory t))))

;; GIVEN fc-match has been asked for a font file once already
;; WHEN it is asked again
;; THEN the same readable path comes back, and its output lands in a
;; reused work buffer, not a fresh one
(if (executable-find "fc-match")
    (battery-check
     "the font finder reuses a buffer"
     (let* ((warm (canvas-minimap--font-file "monospace"))
            found
            (made (battery-buffers-made
                   (lambda ()
                     (setq found (canvas-minimap--font-file "monospace"))))))
       (and warm (equal warm found) (file-readable-p found) (= 0 made))))
  (battery-skip "the font finder reuses a buffer" "no fc-match"))

;; GIVEN some other pool user left a since-deleted directory behind in
;; a work buffer
;; WHEN a font is looked up
;; THEN it is still found -- fc-match must not run in the stale
;; directory (issue #1 follow-up)
(if (executable-find "fc-match")
    (battery-check
     "a stale pool directory does not lose the font"
     (let ((dir (make-temp-file "battery-stale" t)))
       (unwind-protect
           (progn
             (with-work-buffer (setq default-directory dir))
             (delete-directory dir)
             (let ((file (canvas-minimap--font-file "monospace")))
               (and file (file-readable-p file))))
         ;; Leave the pool wholesome for whoever draws from it next.
         (with-work-buffer (setq default-directory temporary-file-directory)))))
  (battery-skip "a stale pool directory does not lose the font" "no fc-match"))

(set-frame-size (selected-frame) 200 45)
(switch-to-buffer battery-src)
(canvas-minimap-mode 1)

;; The steps are pushed in the order they run, and reversed below.

(progn
  (battery-step 0.6
    ;; GIVEN a map settled on the far end of a twelve hundred line buffer
    (battery-jump 1100))
  (battery-step 0.8
    ;; WHEN the window jumps a thousand lines back
    (battery-jump 60))
  (battery-step 1.2
    ;; THEN the map walks there and stops of its own accord
    ;; AND what it settles on is what a redraw from scratch would draw
    (let* ((st (battery-state))
           (settled (copy-sequence (canvas-minimap--state-data st))))
      (battery-check "glide settled" (null canvas-minimap--glide-timer))
      (canvas-minimap-refresh)
      (let ((d (battery-differs settled (canvas-minimap--state-data (battery-state)))))
        (battery-check "settled canvas = fresh render" (eql 0 d)
                       (format "%d px differ" d)))))

  (battery-step 0.4
    ;; GIVEN a settled map over a buffer nobody is touching
    ;; WHEN the update and poll passes run again
    ;; THEN nothing is sent to the canvas
    (setq battery-uploads 0)
    (canvas-minimap--update)
    (canvas-minimap--update)
    (canvas-minimap--poll)
    (battery-check "idle passes upload nothing" (eql 0 battery-uploads)
                   (format "%d uploads" battery-uploads)))

  (battery-step 0.2
    ;; GIVEN a map drawing far more of the buffer than the window shows
    ;; WHEN a point three quarters down it is clicked
    ;; THEN the window scrolls to the line drawn there
    (let* ((st (battery-state))
           (scale (canvas-minimap--state-scale st))
           (y (/ (* 3 (canvas-minimap--state-height st)) (* 4 scale)))
           (slot (/ (max 0 (- (* y scale) (canvas-minimap--state-top st)))
                    (canvas-minimap--state-lh st)))
           (line (aref (canvas-minimap--state-cookies st) slot)))
      (canvas-minimap--goto-y st y)
      (battery-check "a click scrolls to the line it drew"
                     (and (integerp line)
                          (with-current-buffer battery-src
                            (save-excursion
                              (goto-char (point-min))
                              (forward-line (1- line))
                              (pos-visible-in-window-p
                               (point) (canvas-minimap--state-window st)))))
                     (format "slot %d draws line %S, window starts at %S"
                             slot line
                             (with-current-buffer battery-src
                               (line-number-at-pos
                                (window-start (canvas-minimap--state-window st))))))))

  (battery-step 0.3
    ;; GIVEN a settled map of a buffer the window shows a screenful of
    (battery-jump 400)
    (battery-settle))
  (battery-step 0.4
    ;; THEN the tinted band covers the rows drawing the lines in the
    ;; window, and no others
    (let* ((st (battery-state))
           (win (canvas-minimap--state-window st))
           (cookies (canvas-minimap--state-cookies st))
           (wstart (with-current-buffer battery-src
                     (line-number-at-pos (window-start win))))
           (wend (with-current-buffer battery-src
                   (line-number-at-pos (window-end win t))))
           (band (battery-deco-slots st 1))
           (want (let (slots)
                   (dotimes (i (canvas-minimap--state-rows st))
                     (let ((line (aref cookies i)))
                       (when (and (integerp line) (<= wstart line wend))
                         (push i slots))))
                   (nreverse slots))))
      (battery-check "the band covers what the window shows"
                     (and band (equal band want))
                     (format "%d rows tinted, %d lines in the window"
                             (length band) (length want)))))

  (battery-step 0.3
    ;; GIVEN a buffer with fewer lines than the map has rows, so the map
    ;; has empty rows under it, shown from its first line
    (let ((buf (get-buffer-create "short.txt")))
      (with-current-buffer buf
        (erase-buffer)
        (dotimes (i 30) (insert (format "line %d of a short buffer\n" i)))
        (goto-char (point-min)))
      (switch-to-buffer buf)
      (with-selected-window (frame-selected-window) (goto-char (point-min)))
      (redisplay t)
      (canvas-minimap--update)
      (canvas-minimap--update)))
  (battery-step 0.4
    ;; THEN the band covers rows the buffer reaches, and no empty ones:
    ;; a window ending at the end of the buffer does not tint the rest
    ;; of the map
    (let* ((st (battery-state))
           (cookies (canvas-minimap--state-cookies st))
           (band (battery-deco-slots st 1))
           (empty (seq-filter (lambda (i) (not (integerp (aref cookies i)))) band)))
      (battery-check "the band stops where the buffer does"
                     (and band (null empty))
                     (format "%d rows tinted, %d of them empty"
                             (length band) (length empty))))
    (switch-to-buffer battery-src)
    (canvas-minimap--update))

  ;; The viewport can be shown as a tint over its rows or as a line drawn
  ;; round them, which leaves the map\'s own background inside it.
  (battery-step 0.3
    ;; GIVEN a buffer of empty lines, so every row of the map is ground
    (let ((buf (get-buffer-create "empty-lines.txt")))
      (with-current-buffer buf
        (erase-buffer)
        (dotimes (_ 300) (insert "\n"))
        (goto-char (point-min))
        (forward-line 100))
      (switch-to-buffer buf)
      (with-selected-window (frame-selected-window)
        (goto-char (point-min))
        (forward-line 100)
        (recenter))
      (redisplay t)
      (canvas-minimap--update)
      (canvas-minimap--update)))
  (battery-step 0.4
    ;; THEN with the tint, the rows in the viewport are not the ground
    (let* ((st (battery-state))
           (band (battery-deco-slots st 1))
           (mid (nth (/ (length band) 2) band))
           (bg (canvas-minimap--state-bgpix st)))
      (setq battery-band-row mid)
      (battery-check "the viewport tints its rows"
                     (and mid (not (eql (battery-pixel st mid 1 20) bg)))
                     (format "%d rows in the band" (length band))))
    ;; WHEN the viewport is asked for as an outline instead
    (setq canvas-minimap-viewport-style 'outline)
    (canvas-minimap--update)
    (canvas-minimap--update))
  (battery-step 0.4
    ;; THEN the rows keep the map\'s background, with a line down each
    ;; side and one across the top and bottom of the band
    (let* ((st (battery-state))
           (band (battery-deco-slots st 32))
           (top (car band))
           (bottom (car (last band)))
           (mid battery-band-row)
           (bg (canvas-minimap--state-bgpix st))
           (lh (canvas-minimap--state-lh st))
           (edge (canvas-minimap--state-text-x1 st)))
      (battery-check "an outlined viewport keeps the background"
                     (and mid (eql (battery-pixel st mid 1 20) bg))
                     (format "row %S, middle pixel %s the ground" mid
                             (if (and mid (eql (battery-pixel st mid 1 20) bg))
                                 "is" "is not")))
      (battery-check "and draws a line around itself"
                     (and top bottom mid
                          (not (eql (battery-pixel st mid 1 0) bg))
                          (not (eql (battery-pixel st top 0 20) bg))
                          (not (eql (battery-pixel st bottom (1- lh) 20) bg)))
                     (format "band rows %S..%S of %d" top bottom (length band)))
      (ignore edge))
    ;; WHEN the viewport is given a colour of its own, at full strength
    (setq canvas-minimap-viewport-style 'tint
          canvas-minimap-viewport-color "#00ff00"
          canvas-minimap-viewport-alpha 1.0)
    (canvas-minimap--update)
    (canvas-minimap--update))
  (battery-step 0.4
    ;; THEN that is the colour its rows take, without the map having to
    ;; be built again
    (let* ((st (battery-state))
           (band (battery-deco-slots st 1))
           (mid (nth (/ (length band) 2) band))
           (green (canvas-minimap--argb 0 255 0)))
      (battery-check "the viewport colour follows the option"
                     (and mid (eql (battery-pixel st mid 1 20) green))
                     (format "row %S is %s" mid
                             (and mid (format "%08x" (battery-pixel st mid 1 20))))))
    (setq canvas-minimap-viewport-color nil
          canvas-minimap-viewport-alpha 0.22)
    (canvas-minimap--update)
    (switch-to-buffer battery-src)
    (canvas-minimap--update))

  (battery-step 0.3
    ;; GIVEN a map marking the line point is on, highlighted or not
    (setq canvas-minimap-point-defer nil)
    (battery-jump 420)
    (battery-settle))
  (battery-step 0.4
    ;; WHEN point moves to another line the map is drawing
    ;; THEN the marker is on that line's row and on no other
    (let* ((st (battery-state))
           (cookies (canvas-minimap--state-cookies st)))
      (with-selected-window (canvas-minimap--state-window st)
        (forward-line 3))
      (canvas-minimap--update)
      (let* ((pline (with-current-buffer battery-src
                      (line-number-at-pos
                       (window-point (canvas-minimap--state-window st)))))
             (want (let (slot)
                     (dotimes (i (canvas-minimap--state-rows st))
                       (when (eql (aref cookies i) pline) (setq slot i)))
                     slot))
             (marked (battery-deco-slots st 2)))
        (battery-check "the point marker follows point"
                       (equal marked (and want (list want)))
                       (format "marked %S, point is on line %d at row %S"
                               marked pline want))))
    (setq canvas-minimap-point-defer t))

  (battery-step 0.3
    ;; GIVEN a settled map with nothing but text on one of its rows
    (battery-jump 300)
    (battery-settle))
  (battery-step 0.5
    (let* ((st (battery-state))
           (slot 20)
           (line (aref (canvas-minimap--state-cookies st) slot))
           (plain (battery-slot-pixels st slot))
           (ov (with-current-buffer battery-src
                 (save-excursion
                   (goto-char (point-min))
                   (forward-line (1- line))
                   (make-overlay (point) (line-end-position))))))
      ;; WHEN something highlights that line without touching the text,
      ;; as the region and `hl-line' do
      (overlay-put ov 'face 'region)
      (canvas-minimap--poll)
      ;; THEN the poll notices and the row is repainted
      (battery-check "an overlay's highlighting is picked up"
                     (> (battery-differs plain (battery-slot-pixels st slot)) 0)
                     (format "row %d, line %S" slot line))

      ;; WHEN the highlighting goes away again
      (delete-overlay ov)
      (canvas-minimap--poll)
      ;; THEN the row goes back to the pixels it had
      (battery-check "and lifted again when it goes"
                     (eql 0 (battery-differs plain (battery-slot-pixels st slot)))
                     (format "%d px differ"
                             (battery-differs plain (battery-slot-pixels st slot))))))

  (battery-step 0.3
    ;; GIVEN a map drawn over the middle of the buffer
    (battery-jump 600)
    (with-current-buffer battery-src
      (goto-char (point-min)) (forward-line 601) (end-of-line)
      (setq canvas-minimap--dirty nil)

      ;; WHEN a character is typed into a line
      (insert "x")

      ;; THEN that line alone is marked for redrawing
      (let ((dirty canvas-minimap--dirty))
        (battery-check "a keystroke redraws its own line"
                       (and dirty (< (cdr dirty) most-positive-fixnum))
                       (format "%S" dirty)))
      (setq canvas-minimap--dirty nil)

      ;; WHEN the edit adds a line instead
      (insert "\n")

      ;; THEN everything below it is marked too, since every line moved
      (let ((dirty canvas-minimap--dirty))
        (battery-check "a new line redraws the tail"
                       (and dirty (eql (cdr dirty) most-positive-fixnum))
                       (format "%S" dirty)))))

  (battery-step 0.3
    ;; GIVEN a settled map three hundred rows tall
    (battery-jump 700))
  (battery-step 0.8
    ;; WHEN the window scrolls a few lines
    ;; THEN what is still on the map is moved rather than drawn again,
    ;; AND only the lines that came into view are rasterized
    (let* ((st (battery-state))
           (rows (canvas-minimap--state-rows st))
           (drawn (battery-drawn
                   (lambda ()
                     (with-selected-window (canvas-minimap--state-window st)
                       (scroll-up 5))
                     (canvas-minimap--update)))))
      (battery-check "a small scroll draws only what moved in"
                     (< drawn (/ rows 4))
                     (format "%d of %d rows" drawn rows))))

  (battery-step 0.3
    ;; GIVEN a settled map over the lines about to change
    (battery-jump 604)
    (battery-settle)

    ;; WHEN a mixed run of edits lands: typing, a delete, a line added,
    ;; a line killed, and an edit above them all
    (with-current-buffer battery-src
      (goto-char (point-min)) (forward-line 604) (end-of-line)
      (insert "  ;; typed here")
      (backward-delete-char 3)
      (beginning-of-line) (insert "prefix ")
      (forward-line 3) (insert "a new line\n")
      (forward-line 2) (kill-whole-line)
      (forward-line -8) (end-of-line) (insert "!"))
    (canvas-minimap--update)
    (canvas-minimap--update))
  (battery-step 0.5
    ;; THEN the map drawn one change at a time holds the same pixels as
    ;; one drawn from scratch
    (battery-settle)
    (let* ((st (battery-state))
           (drawn (copy-sequence (canvas-minimap--state-data st))))
      (canvas-minimap-refresh)
      (let ((d (battery-differs drawn (canvas-minimap--state-data (battery-state)))))
        (battery-check "incremental edits = fresh render" (eql 0 d)
                       (format "%d px differ" d)))))

  (battery-step 0.3
    ;; GIVEN a completion whose candidates carry buffer positions, the
    ;; way `consult-line' leaves them
    (battery-jump 500)
    (let* ((st (battery-state))
           (rows (canvas-minimap--state-rows st))
           (lines '(505 510 520))
           (cands (with-current-buffer battery-src
                    (save-excursion
                      (mapcar (lambda (l)
                                (goto-char (point-min))
                                (forward-line (1- l))
                                (propertize (format "line %d" l)
                                            'consult-location
                                            (cons (cons battery-src (point)) l)))
                              lines))))
           (table (lambda (string pred action)
                    (if (eq action 'metadata)
                        '(metadata (category . consult-location))
                      (complete-with-action action cands string pred)))))
      ;; The THEN is scheduled before the WHEN below because it has to
      ;; look while the minibuffer is still up.
      (run-at-time
       0.4 nil
       (lambda ()
         ;; THEN the map marks the slots drawing those lines, and no others
         (let* ((hits (canvas-minimap--match-hits st battery-src rows))
                (marked (let (slots)
                          (dotimes (i rows)
                            (when (and hits (aref hits i)) (push i slots)))
                          (nreverse slots)))
                (want (delq nil (mapcar (lambda (l)
                                          (canvas-minimap--slot-of-line st l))
                                        lines))))
           (battery-check "matched lines are marked" (equal marked want)
                          (format "marked %S, want %S" marked want)))
         (exit-minibuffer)))
      ;; WHEN it is matching in the minibuffer
      (let ((unread-command-events (listify-key-sequence "line")))
        (condition-case nil (completing-read "find: " table nil nil)
          ((quit error) nil)))))

  (battery-step 0.4
    ;; GIVEN an org buffer with its subtrees open
    (switch-to-buffer battery-org)
    (canvas-minimap--update))
  (battery-step 0.5
    ;; WHEN the subtrees are folded away
    ;; THEN the body lines leave the map AND the headings move up into
    ;; the rows they had
    (let ((open (battery-cookies (battery-state) 12)))
      (with-current-buffer battery-org (org-overview))
      (redisplay t)
      (canvas-minimap--update)
      (canvas-minimap--update)
      (let ((closed (battery-cookies (battery-state) 12)))
        (battery-check "folding drops the hidden lines"
                       (and (equal (cl-subseq open 0 4) '(1 2 3 4))
                            (equal (cl-subseq closed 0 4) '(1 7 13 19)))
                       (format "open %S closed %S"
                               (cl-subseq open 0 6) (cl-subseq closed 0 6))))))

  (battery-step 0.3
    ;; GIVEN a buffer narrowed to forty lines starting at line 400
    (switch-to-buffer battery-src)
    (with-current-buffer battery-src
      (widen)
      (goto-char (point-min))
      (forward-line 399)
      (narrow-to-region (point) (save-excursion (forward-line 40) (point)))
      (goto-char (point-min)))
    (redisplay t)
    (canvas-minimap--update)
    (canvas-minimap--update))
  (battery-step 0.3
    ;; THEN the map draws that region rather than the top of the file
    (let ((first (aref (canvas-minimap--state-cookies (battery-state)) 0)))
      (battery-check "a narrowed buffer maps its own region"
                     (and (integerp first) (< 300 first 401))
                     (format "slot 0 draws line %S, narrowing starts at 400" first)))
    (with-current-buffer battery-src (widen)))

  (battery-step 0.3
    ;; GIVEN an overlay the map has taken note of, near the end of the buffer
    (battery-jump 1100)
    (let* ((st (battery-state))
           (beg (marker-position (canvas-minimap--state-slice-beg st)))
           (ov (with-current-buffer battery-src
                 (make-overlay beg (min (point-max) (+ beg 40))))))
      (overlay-put ov 'face 'region)
      (canvas-minimap--poll)

      ;; WHEN the overlay goes and the buffer shrinks past where it was
      (delete-overlay ov)
      (with-current-buffer battery-src
        (erase-buffer)
        (insert (make-string 300 ?x)))

      ;; THEN the next poll gets through, rather than signalling on a
      ;; position the buffer no longer has
      (battery-check "the poll survives the buffer shrinking"
                     (condition-case err (progn (canvas-minimap--poll) t)
                       (error (battery-say "   %S" err) nil)))))

  (battery-step 0.3
    ;; GIVEN a buffer with an image displayed on one of its lines
    (let ((png (expand-file-name "images/splash.png" data-directory))
          (buf (get-buffer-create "img.txt")))
      (if (not (file-readable-p png))
          (battery-skip "an image line claims several rows" "no image to draw")
        (with-current-buffer buf
          (erase-buffer)
          (dotimes (i 200) (insert (format "text line %d\n" i)))
          ;; Well down the buffer, so the row it lands on is clear of the
          ;; viewport band and the point marker.
          (goto-char (point-min))
          (forward-line 100)
          (insert "IMG\n")
          (put-text-property (line-beginning-position -1)
                             (1- (line-beginning-position))
                             'display (create-image png))
          (goto-char (point-min)))
        ;; WHEN the map draws it
        (switch-to-buffer buf)
        (redisplay t)
        (canvas-minimap--update)
        (canvas-minimap--update))))
  (battery-step 1.5
    ;; THEN that line takes as many rows as it does on screen
    ;; AND the rows hold the picture rather than the text underneath it
    ;; AND the picture is downsampled into them
    (let* ((st (battery-state))
           (parts (canvas-minimap--state-parts st))
           (rows (let (r)
                   (dotimes (i (canvas-minimap--state-rows st))
                     (when (> (aref parts i) 0) (push i r)))
                   (nreverse r))))
      (when (get-buffer "img.txt")
        (battery-check "an image line claims several rows" (> (length rows) 1)
                       (format "rows of a multi-row line: %S" rows))
        ;; The first row of the line, which is the one part 0 sits on.
        (setq battery-picture-slot (and rows (1- (car rows)))
              battery-picture-line (and rows
                                        (aref (canvas-minimap--state-cookies st)
                                              (1- (car rows))))
              battery-picture-row (and rows
                                       (battery-slot-pixels st (1- (car rows)))))
        (if (zerop (hash-table-count canvas-minimap--thumbs))
            (if battery-pillow
                (battery-check "the image was downsampled" nil "nothing rasterized")
              (battery-skip "the image was downsampled" "python3 with Pillow missing"))
          (battery-check "the image was downsampled" t)))))
  (battery-step 0.3
    ;; WHEN the picture is taken off the line, leaving the words that
    ;; were under it
    (when (get-buffer "img.txt")
      (with-current-buffer "img.txt"
        (remove-text-properties (point-min) (point-max) '(display nil)))
      (canvas-minimap-refresh)))
  (battery-step 0.6
    ;; THEN that line, drawn now as the words it holds, looks nothing
    ;; like the row the map drew while the picture was on it
    (when battery-picture-row
      (let* ((st (battery-state))
             (cookies (canvas-minimap--state-cookies st))
             (slot (let (found)
                     (dotimes (i (canvas-minimap--state-rows st))
                       (when (and (not found)
                                  (eql (aref cookies i) battery-picture-line))
                         (setq found i)))
                     found))
             (words (and slot (battery-slot-pixels st slot))))
        (battery-check "the picture is drawn, not the words under it"
                       (and words (> (battery-differs battery-picture-row words) 0))
                       (format "line %S: %S px differ from the same line as words"
                               battery-picture-line
                               (and words
                                    (battery-differs battery-picture-row words)))))))


  ;;;; The strip, the window handling, and the shape of the canvas

  (battery-step 0.3
    ;; GIVEN a whole source buffer again -- the checks above left it in
    ;; pieces -- shown in one of the frame's two windows
    (with-current-buffer battery-src
      (widen)
      (erase-buffer)
      (dotimes (i 1200) (insert (format ";; line %d  (defun f%d () %d)\n" i i i)))
      (goto-char (point-min)))
    (switch-to-buffer battery-src)
    (split-window-right)
    (canvas-minimap--update)
    (canvas-minimap--update))

  (battery-step 0.4
    ;; THEN no strip is drawn, because none was asked for
    (battery-check "no strip unless it is asked for"
                   (eql 0 (canvas-minimap--state-top (battery-state)))
                   (format "top = %S" (canvas-minimap--state-top (battery-state))))
    ;; WHEN the strip is turned on
    (setq canvas-minimap-layout-height 'auto)
    (canvas-minimap-refresh))

  (battery-step 0.5
    (let* ((st (battery-state))
           (frame (selected-frame))
           (top (canvas-minimap--state-top st))
           (plan (canvas-minimap--layout-windows frame))
           (panes (seq-remove #'canvas-minimap--minimap-window-p
                              (window-list frame 'no-mini))))
      ;; THEN it appears at the top of the map
      ;; AND its plan holds the windows you can work in, not the maps
      (battery-check "the strip is drawn" (> top 0) (format "top = %S" top))
      (battery-check "the plan leaves the maps out"
                     (and (equal plan panes) (= 2 (length plan)))
                     (format "%d panes of %d windows"
                             (length plan) (length (window-list frame 'no-mini))))

      ;; WHEN the strip is pointed at column by column
      ;; THEN every pane is reachable AND nothing below the strip is
      (let (found)
        (dotimes (i 40)
          (let ((w (canvas-minimap--layout-window-at
                    st (/ (* i (canvas-minimap--state-width st)) 40) (/ top 2))))
            (when (and w (not (memq w found))) (push w found))))
        (battery-check "every pane can be clicked"
                       (and (= (length found) (length plan))
                            (cl-every (lambda (w) (memq w plan)) found))
                       (format "%d of %d panes" (length found) (length plan)))
        (battery-check "below the strip is not the plan"
                       (null (canvas-minimap--layout-window-at st 10 (+ top 4)))))

      ;; THEN the plan spans the columns the map draws its text in: the
      ;; strip and the picture under it are one thing at two scales
      (pcase-let* ((`(,bx ,iw ,_ih) (canvas-minimap--layout-area st))
                   (sc (canvas-minimap--state-scale st))
                   (tx0 (canvas-minimap--state-text-x0 st))
                   (tx1 (canvas-minimap--state-text-x1 st)))
        (battery-check "the plan lines up with the map"
                       (and (<= (abs (- bx tx0)) sc)
                            (<= (abs (- (+ bx iw) tx1)) (* 2 sc)))
                       (format "plan %d..%d, text %d..%d" bx (+ bx iw) tx0 tx1)))))

  (battery-step 0.3
    ;; WHEN the strip is told to fill the current pane with an opaque green
    (setq canvas-minimap-layout-color "#00ff00"
          canvas-minimap-layout-alpha 1.0)
    (canvas-minimap-refresh))
  (battery-step 0.5
    ;; THEN that is the colour it is filled with
    (let* ((st (battery-state))
           (data (canvas-minimap--state-data st))
           (green (canvas-minimap--argb 0 255 0))
           (n 0))
      (dotimes (i (* (canvas-minimap--state-width st)
                     (canvas-minimap--state-top st)))
        (when (eql (aref data i) green) (setq n (1+ n))))
      (battery-check "the strip takes the colour it is given" (> n 100)
                     (format "%d pixels of it" n)))
    (setq canvas-minimap-layout-color nil
          canvas-minimap-layout-alpha 0.55)
    (canvas-minimap-refresh))

  (battery-step 0.4
    ;; GIVEN the strip on, and the frame split in two
    ;; WHEN the other window is deleted
    (delete-other-windows)
    (canvas-minimap--update)
    (canvas-minimap--update))
  (battery-step 0.4
    ;; THEN the strip goes: a plan of one window has nothing to tell apart
    (let ((top (canvas-minimap--state-top (battery-state))))
      (battery-check "the strip goes with the last split"
                     (and (eql 0 top)
                          (= 1 (length (canvas-minimap--layout-windows (selected-frame)))))
                     (format "top = %S with %d window(s)" top
                             (length (canvas-minimap--layout-windows (selected-frame))))))
    ;; WHEN the window is split again
    (split-window-right)
    (canvas-minimap--update)
    (canvas-minimap--update))
  (battery-step 0.4
    ;; THEN the strip is back
    (let ((top (canvas-minimap--state-top (battery-state))))
      (battery-check "and comes back with a split" (> top 0) (format "top = %S" top)))
    ;; WHEN told to draw the plan even for one window, and left with one
    (setq canvas-minimap-layout-always t)
    (delete-other-windows)
    (canvas-minimap--update)
    (canvas-minimap--update))
  (battery-step 0.4
    ;; THEN it stays
    (let ((top (canvas-minimap--state-top (battery-state))))
      (battery-check "unless it is wanted whatever the count"
                     (and (> top 0)
                          (= 1 (length (canvas-minimap--layout-windows (selected-frame)))))
                     (format "top = %S with %d window(s)" top
                             (length (canvas-minimap--layout-windows (selected-frame))))))
    (setq canvas-minimap-layout-always nil
          canvas-minimap-layout-height nil)
    (split-window-right)
    (canvas-minimap-refresh))

  (battery-step 0.4
    ;; GIVEN a map drawn in a window that truncates lines, whose last
    ;; character cell is kept for the continuation glyph and never
    ;; reaches the screen
    ;; THEN the canvas stops a cell short of the window body
    (let* ((st (battery-state))
           (mm (canvas-minimap--frame-window (selected-frame)))
           (px (/ (canvas-minimap--state-width st)
                  (canvas-minimap--state-scale st))))
      (battery-check "the canvas leaves the last cell spare"
                     (<= (+ px (frame-char-width)) (window-body-width mm t))
                     (format "canvas %d px + cell %d in body %d px"
                             px (frame-char-width) (window-body-width mm t)))))

  (battery-step 0.3
    ;; GIVEN a map at whatever width it is
    ;; WHEN it is widened by a step
    (setq battery-width (canvas-minimap--state-width (battery-state)))
    (canvas-minimap-widen)
    (canvas-minimap--update))
  (battery-step 0.4
    ;; THEN the canvas is wider than it was
    (battery-check "widening widens the canvas"
                   (> (canvas-minimap--state-width (battery-state)) battery-width)
                   (format "%d -> %d" battery-width
                           (canvas-minimap--state-width (battery-state))))
    ;; WHEN it is narrowed again
    (canvas-minimap-narrow)
    (canvas-minimap--update))
  (battery-step 0.4
    ;; THEN it is back where it started
    (battery-check "narrowing puts it back"
                   (eql (canvas-minimap--state-width (battery-state)) battery-width)
                   (format "%d" (canvas-minimap--state-width (battery-state)))))

  (battery-step 0.3
    ;; GIVEN a map settled over the middle of the buffer
    (with-current-buffer battery-src
      (goto-char (point-min))
      (forward-line 200)
      (recenter))
    (canvas-minimap--update))
  (battery-step 0.4
    ;; WHEN a line it draws gets a fringe indicator, the way diff-hl and
    ;; flymake put one there
    (let* ((st (battery-state))
           (line (aref (canvas-minimap--state-cookies st) 4))
           (ov (with-current-buffer battery-src
                 (save-excursion
                   (goto-char (point-min))
                   (forward-line (1- line))
                   (make-overlay (point) (point))))))
      (overlay-put ov 'before-string
                   (propertize " " 'display '(left-fringe filled-square success)))
      (canvas-minimap--update)

      ;; THEN the gutter is coloured beside that line AND beside no other
      (let* ((marks (canvas-minimap--fringe-marks
                     st battery-src (canvas-minimap--state-window st)
                     (canvas-minimap--state-rows st)))
             (marked (cl-count-if #'identity (append marks nil))))
        (battery-check "a fringe indicator reaches the gutter"
                       (and (aref marks 4) (eql marked 1))
                       (format "%d marked in all, slot 4 %s" marked
                               (if (aref marks 4) "coloured" "empty"))))
      (delete-overlay ov)))

  (battery-step 0.3
    ;; GIVEN a buffer whose eleventh line opens with text the display
    ;; hides, as an org link does with its brackets
    (let ((buf (get-buffer-create "hidden.txt")))
      (with-current-buffer buf
        (erase-buffer)
        (dotimes (i 40) (insert (format "line %d\n" i)))
        (goto-char (point-min))
        (forward-line 10)
        (let ((start (point)))
          (insert "[[hidden]]shown\n")
          (put-text-property start (+ start 10) 'invisible t))
        (goto-char (point-min)))
      (switch-to-buffer buf)
      (redisplay t)
      (canvas-minimap--update)
      (canvas-minimap--update)))
  (battery-step 0.4
    ;; THEN the map still draws that line: what is hidden is its opening,
    ;; not the line
    (let ((lines (battery-cookies (battery-state) 16)))
      (battery-check "a line that starts hidden is still drawn"
                     (memq 11 lines) (format "%S" lines))))

  (battery-step 0.3
    ;; GIVEN one line with text hidden away in the middle of it -- what
    ;; an org link does with everything but its description -- beside
    ;; the same line with nothing hidden, and one holding only the part
    ;; that shows
    (let ((buf (get-buffer-create "hidden-run.txt")))
      (with-current-buffer buf
        (erase-buffer)
        (insert "start end of it\n")
        (let ((b (point)))
          (insert "start hidden-part-here-and-more end of it\n")
          (put-text-property (+ b 6) (+ b 32) 'invisible t))
        (insert "start hidden-part-here-and-more end of it\n")
        (dotimes (i 60) (insert (format "filler %d\n" i)))
        (goto-char (point-max)))
      (switch-to-buffer buf)
      (redisplay t)
      (canvas-minimap--update)
      (canvas-minimap--update)))
  (battery-step 0.4
    ;; THEN the map draws that line as long as what shows of it, not as
    ;; long as what it holds
    (let* ((st (battery-state))
           (shows (battery-ink-end st (battery-slot-of st 1)))
           (hidden (battery-ink-end st (battery-slot-of st 2)))
           (whole (battery-ink-end st (battery-slot-of st 3))))
      (battery-check "text hidden inside a line is not drawn"
                     (and shows hidden whole
                          (< (abs (- hidden shows)) 3)
                          (> whole (+ hidden 5)))
                     (format "ends at %S hidden, %S showing only what shows, %S with it all"
                             hidden shows whole))))

  (battery-step 0.3
    ;; GIVEN a buffer whose lines open with an icon the height of the
    ;; text beside it -- what svg-lib and the icon packages put there --
    ;; with the same words on the lines between them
    (let ((png (expand-file-name "images/splash.png" data-directory))
          (buf (get-buffer-create "icons.txt")))
      (with-current-buffer buf
        (erase-buffer)
        ;; Three kinds of line, over and over: no icon, an icon the
        ;; height of the text, and one taller than the line it is on.
        (dotimes (i 200)
          (pcase (mod i 3)
            (0 (insert " "))
            (1 (insert (propertize " " 'display
                                   (create-image png nil nil
                                                 :height (frame-char-height)
                                                 :ascent 'center))))
            (_ (insert (propertize " " 'display
                                   (create-image png nil nil
                                                 :height (* 2 (frame-char-height))
                                                 :ascent 'center)))))
          (insert (format " section %d with words on it\n" i)))
        (goto-char (point-min)))
      (switch-to-buffer buf)
      (with-selected-window (frame-selected-window)
        (goto-char (point-min))
        (forward-line 150)
        (recenter))
      (redisplay t)
      (canvas-minimap--update)
      (canvas-minimap--update)))
  (battery-step 0.5
    ;; THEN those lines are drawn as the text they are: an icon is
    ;; decoration, and a line is not a picture because one sits on it
    (let* ((st (battery-state))
           (cookies (canvas-minimap--state-cookies st))
           (found (make-vector 3 nil)))
      (dotimes (i (canvas-minimap--state-rows st))
        (let ((line (aref cookies i)))
          (when (and (integerp line)
                     (eql (aref (canvas-minimap--state-parts st) i) 0))
            (let ((kind (mod (1- line) 3)))
              (unless (aref found kind) (aset found kind i))))))
      (let ((plain (and (aref found 0) (battery-ink st (aref found 0) 8)))
            (icon (and (aref found 1) (battery-ink st (aref found 1) 8)))
            (tall (and (aref found 2) (battery-ink st (aref found 2) 8))))
        (battery-check "a line with an icon still draws its text"
                       (and plain icon tall (> plain 0)
                            (> icon (/ plain 2)) (> tall (/ plain 2)))
                       (format "ink past the icon %S, past a tall icon %S, plain %S"
                               icon tall plain)))))

  (battery-step 0.3
    ;; GIVEN a buffer in a mode the map is told to leave alone
    ;; WHEN it is selected
    (let ((buf (get-buffer-create "excluded")))
      (with-current-buffer buf
        (erase-buffer)
        (insert "x")
        (setq major-mode 'image-mode))
      (switch-to-buffer buf)
      (canvas-minimap--update)
      (canvas-minimap--update)))
  (battery-step 0.3
    ;; THEN no map is put beside it
    (battery-check "an excluded mode gets no map"
                   (null (canvas-minimap--frame-window (selected-frame))))
    (switch-to-buffer battery-src)
    (canvas-minimap--update))

  (battery-step 0.4
    ;; GIVEN a frame of two windows
    ;; WHEN a map per window is asked for instead of one per frame
    (setq canvas-minimap-placement 'window)
    (canvas-minimap--update)
    (canvas-minimap--update))
  (battery-step 0.5
    ;; THEN there is one beside each of them
    (let ((maps (length (canvas-minimap--windows (selected-frame)))))
      (battery-check "a map beside every window when asked for" (eql 2 maps)
                     (format "%d maps" maps)))
    (setq canvas-minimap-placement 'frame)
    (canvas-minimap--update)
    (canvas-minimap--update))

  (battery-step 0.5
    ;; WHEN the window jumps hundreds of lines
    ;; THEN the map walks after it rather than cutting to it
    (battery-jump 900)
    (battery-check "a long jump glides" (and canvas-minimap--glide-timer t)))
  (battery-step 1.5
    ;; GIVEN the map being scrubbed with the mouse, where a walk would
    ;; only lag behind the hand
    ;; WHEN the same jump happens
    ;; THEN it snaps there instead
    (let ((canvas-minimap--dragging t))
      (battery-jump 100))
    (battery-check "a drag does not glide" (null canvas-minimap--glide-timer)))
  (battery-step 0.6
    ;; WHEN another buffer is switched to, which has nothing to walk from
    ;; THEN it snaps there too
    (switch-to-buffer battery-org)
    (canvas-minimap--update)
    (battery-check "a buffer switch does not glide" (null canvas-minimap--glide-timer))
    (switch-to-buffer battery-src)
    (canvas-minimap--update))

  ;; A window cannot be moved, so a map that is on the wrong side -- told
  ;; to change sides, or pushed off the frame's edge by something that
  ;; split the root window -- has to be built again where it belongs.
  (battery-step 0.3
    ;; WHEN the map is told to sit on the other side of the frame
    (setq canvas-minimap-side 'left)
    (canvas-minimap--update)
    (canvas-minimap--update))
  (battery-step 0.4
    ;; THEN that is the side it is standing on
    (let ((mm (canvas-minimap--frame-window (selected-frame))))
      (battery-check "the map takes the side it is told"
                     (and (window-live-p mm) (window-at-side-p mm 'left))
                     (format "left edge: %S, right edge: %S"
                             (and mm (window-at-side-p mm 'left))
                             (and mm (window-at-side-p mm 'right)))))
    (setq canvas-minimap-side 'right)
    (canvas-minimap--update)
    (canvas-minimap--update))

  (battery-step 0.3
    ;; WHEN the fringe strip is given no width
    (setq canvas-minimap-gutter-width 0)
    (canvas-minimap-refresh))
  (battery-step 0.4
    ;; THEN no columns of the map are kept for it
    (let ((st (battery-state)))
      (battery-check "no gutter when its width is zero"
                     (eql (canvas-minimap--state-gut-x0 st)
                          (canvas-minimap--state-gut-x1 st))
                     (format "gutter columns %d..%d"
                             (canvas-minimap--state-gut-x0 st)
                             (canvas-minimap--state-gut-x1 st))))
    (setq canvas-minimap-gutter-width 3)
    (canvas-minimap-refresh))

  (battery-step 0.3
    ;; GIVEN the rows a map holds at three pixels to the line
    (setq battery-rows (canvas-minimap--state-rows (battery-state)))
    ;; WHEN lines are drawn twice as tall
    (setq canvas-minimap-line-height 6)
    (canvas-minimap-refresh))
  (battery-step 0.4
    ;; THEN it holds about half as many
    (let ((rows (canvas-minimap--state-rows (battery-state))))
      (battery-check "taller lines mean fewer rows"
                     (and (< rows battery-rows)
                          (< (abs (- rows (/ battery-rows 2))) 4))
                     (format "%d rows, was %d" rows battery-rows)))
    (setq canvas-minimap-line-height 3)
    (canvas-minimap-refresh))

  (battery-step 0.3
    ;; GIVEN a buffer with nothing in it at all
    (let ((buf (get-buffer-create "empty.txt")))
      (with-current-buffer buf (erase-buffer))
      (switch-to-buffer buf)
      (redisplay t)
      (canvas-minimap--update)
      (canvas-minimap--update)))
  (battery-step 0.4
    ;; THEN the map draws its one empty line and stops there
    (let ((st (battery-state)))
      (battery-check "an empty buffer draws without complaint"
                     (and (eql 1 (aref (canvas-minimap--state-cookies st) 0))
                          (null (aref (canvas-minimap--state-cookies st) 1)))
                     (format "first rows: %S" (battery-cookies st 3))))
    (switch-to-buffer battery-src)
    (canvas-minimap--update))

  (battery-step 0.4
    ;; GIVEN the package's options, as `customize-group' lists them
    ;; WHEN the menu is opened
    ;; THEN it offers every one of them, and nothing that is not one
    (let ((options (cl-loop for (sym kind) in (get 'canvas-minimap 'custom-group)
                            when (eq kind 'custom-variable) collect sym))
          (offered (progn (canvas-minimap-menu)
                          (cl-loop for obj in transient--suffixes
                                   when (cl-typep obj 'transient-lisp-variable)
                                   collect (oref obj variable)))))
      (battery-check "the menu offers every option"
                     (and options
                          (null (cl-set-difference options offered))
                          (null (cl-set-difference offered options)))
                     (format "%d options, missing %S, extra %S"
                             (length options)
                             (cl-set-difference options offered)
                             (cl-set-difference offered options))))
    ;; GIVEN the map drawn at some height per line
    ;; WHEN the line height is doubled through the menu
    ;; THEN the map is redrawn then and there, with about half the rows
    (let ((rows (canvas-minimap--state-rows (battery-state)))
          (height canvas-minimap-line-height))
      (execute-kbd-macro (kbd (format "l h %d RET" (* 2 height))))
      (let ((now (canvas-minimap--state-rows (battery-state))))
        (battery-check "a change in the menu is drawn at once"
                       (and (eql canvas-minimap-line-height (* 2 height))
                            (< (abs (- now (/ rows 2))) 4))
                       (format "%d rows, was %d" now rows)))
      (execute-kbd-macro (kbd (format "l h %d RET" height))))
    ;; WHEN a switch is pressed
    ;; THEN it flips, with no prompt to answer
    (let ((detail canvas-minimap-glyph-detail))
      (execute-kbd-macro (kbd "l d"))
      (battery-check "a switch flips without a prompt"
                     (eq canvas-minimap-glyph-detail (not detail))
                     (format "%S -> %S" detail canvas-minimap-glyph-detail))
      (execute-kbd-macro (kbd "l d")))
    ;; WHEN a colour is given, and then cleared again
    ;; THEN the menu shows the cleared one by what it falls back to
    (execute-kbd-macro (kbd "v c red RET"))
    (let ((set canvas-minimap-viewport-color))
      (execute-kbd-macro (kbd "v c RET"))
      (battery-check "a cleared colour is shown by its fallback"
                     (and (equal set "red")
                          (null canvas-minimap-viewport-color)
                          (with-current-buffer transient--buffer-name
                            (save-excursion
                              (goto-char (point-min))
                              (search-forward "Region background" nil t))))
                     (format "set %S, cleared %S" set canvas-minimap-viewport-color)))
    ;; GIVEN an option whose value runs to a few hundred characters
    ;; WHEN the menu is drawn again
    ;; THEN every line of it still fits the frame, the value cut short
    (let ((modes canvas-minimap-exclude-modes))
      (setq canvas-minimap-exclude-modes
            (mapcar (lambda (i) (intern (format "some-long-named-mode-%d" i)))
                    (number-sequence 1 12)))
      (execute-kbd-macro (kbd "R"))
      (let ((widest (with-current-buffer transient--buffer-name
                      (apply #'max (mapcar #'length
                                           (split-string (buffer-string) "\n"))))))
        (battery-check "the menu fits the frame"
                       (<= widest (frame-width))
                       (format "widest line %d columns, frame %d" widest (frame-width))))
      (setq canvas-minimap-exclude-modes modes))
    ;; GIVEN the viewport drawn as an outline
    ;; WHEN the menu is drawn again
    ;; THEN the tint's colour and alpha are dimmed, with the style's key as
    ;; the reason, AND the outline colour is not
    (let ((style canvas-minimap-viewport-style))
      (setq canvas-minimap-viewport-style 'outline)
      (execute-kbd-macro (kbd "R"))
      (let ((colour (battery-menu-line "vc Colour"))
            (alpha (battery-menu-line "va Alpha"))
            (outline (battery-menu-line "vo Outline colour")))
        (battery-check "an option another one switches off is dimmed"
                       (and (cdr colour) (cdr alpha) (not (cdr outline))
                            (string-search "(vs is outline)" (car colour))
                            (string-search "(vs is outline)" (car alpha)))
                       (format "%S" (list colour alpha outline))))
      ;; WHEN the style goes back to tinting
      ;; THEN it is the outline colour that is dimmed, and says why
      (setq canvas-minimap-viewport-style 'tint)
      (execute-kbd-macro (kbd "R"))
      (let ((colour (battery-menu-line "vc Colour"))
            (outline (battery-menu-line "vo Outline colour")))
        (battery-check "and the other way round"
                       (and (not (cdr colour)) (cdr outline)
                            (string-search "(vs is tint)" (car outline)))
                       (format "%S" (list colour outline))))
      (setq canvas-minimap-viewport-style style))
    ;; WHEN the point marker is switched off through the menu itself
    ;; THEN the marker's colour dims at once, AND comes back with the marker
    (execute-kbd-macro (kbd "p p"))
    (let ((off (battery-menu-line "pc Colour")))
      (execute-kbd-macro (kbd "p p"))
      (let ((on (battery-menu-line "pc Colour")))
        (battery-check "a switch in the menu dims what it turns off"
                       (and (cdr off) (string-search "(pp is off)" (car off))
                            (not (cdr on)))
                       (format "off %S, on %S" off on))))
    ;; WHEN the mode's own switch is pressed, twice
    ;; THEN the map goes away with the first press AND is back with the
    ;; second, not merely the variable flipped under a running map
    (execute-kbd-macro (kbd "M"))
    (let ((gone (and (null canvas-minimap-mode)
                     (null (canvas-minimap--frame-window (selected-frame))))))
      (execute-kbd-macro (kbd "M"))
      (battery-check "the mode is switched from the menu"
                     (and gone canvas-minimap-mode
                          (window-live-p (canvas-minimap--frame-window (selected-frame))))
                     (format "gone %S, back %S" gone
                             (and canvas-minimap-mode
                                  (window-live-p (canvas-minimap--frame-window (selected-frame)))))))
    ;; GIVEN the viewport tinted
    ;; WHEN the style's key is pressed, with no prompt to answer
    ;; THEN the viewport is outlined, and drawn so there and then; AND two
    ;; more presses take it through both and round to tint again
    (execute-kbd-macro (kbd "v s"))
    (let* ((st (battery-state))
           (outlined (and (eq canvas-minimap-viewport-style 'outline)
                          (battery-deco-slots st 32)
                          (null (battery-deco-slots st 1)))))
      (execute-kbd-macro (kbd "v s"))
      (let ((both (and (eq canvas-minimap-viewport-style 'both)
                       (battery-deco-slots st 32) (battery-deco-slots st 1))))
        (execute-kbd-macro (kbd "v s"))
        (battery-check "a choice cycles with each press, drawn each time"
                       (and outlined both (eq canvas-minimap-viewport-style 'tint))
                       (format "outlined %S, both %S, then %S" (and outlined t) (and both t)
                               canvas-minimap-viewport-style)))))

  (battery-step 0.3
    ;; GIVEN the menu up on a map laid out three pixels to the line
    ;; WHEN a line height is typed at its prompt and looked at, not entered
    ;; THEN the map is already laid out at that height
    (let ((lh (canvas-minimap--state-lh (battery-state))))
      (battery-probe-with
       (lambda () (list (and (active-minibuffer-window) t)
                        canvas-minimap-line-height
                        (canvas-minimap--state-lh (battery-state)))))
      ;; WHEN the prompt is then quit
      (condition-case nil (execute-kbd-macro (kbd "l h 6 <f9> C-g")) (quit nil))
      (pcase-let ((`(,prompt ,height ,then) (car battery-probed)))
        (battery-check "a value is drawn as it is typed"
                       (and prompt (eql height 6) (eql then 6))
                       (format "laid out at %S while typing, was %S, prompt %s, height %S"
                               then lh (if prompt "up" "gone") height)))
      ;; THEN the height and the map are as they were, and the menu is
      ;; back on screen, not merely still active
      (let ((now (canvas-minimap--state-lh (battery-state))))
        (battery-check "and put back when the prompt is quit"
                       (and (not (active-minibuffer-window))
                            (eql canvas-minimap-line-height 3)
                            (eql now lh)
                            (window-live-p (get-buffer-window transient--buffer-name)))
                       (format "laid out at %S, was %S, height %S, menu %s" now lh
                               canvas-minimap-line-height
                               (cond ((window-live-p (get-buffer-window transient--buffer-name)) "shown")
                                     (transient--prefix "active but hidden")
                                     (t "gone"))))))
    ;; GIVEN the viewport tinted at full strength
    ;; WHEN a colour is typed at the tint colour's prompt and looked at
    ;; THEN the band is already that colour
    (setq canvas-minimap-viewport-alpha 1.0)
    (canvas-minimap-refresh)
    (let ((green (canvas-minimap--argb 0 255 0)))
      (battery-probe-with
       (lambda () (let* ((st (battery-state))
                         (band (battery-deco-slots st 1))
                         (mid (nth (/ (length band) 2) band)))
                    (list (and (active-minibuffer-window) t) mid
                          (and mid (battery-pixel st mid 1 20))))))
      ;; WHEN it is then entered
      (execute-kbd-macro (kbd "v c # 0 0 f f 0 0 <f9> RET"))
      (pcase-let ((`(,prompt ,mid ,pixel) (car battery-probed)))
        (battery-check "a colour is drawn as it is typed"
                       (and prompt mid (eql pixel green))
                       (format "row %S is %s while typing, prompt %s" mid
                               (and pixel (format "%08x" pixel))
                               (if prompt "up" "gone"))))
      ;; THEN it stays, and the menu is back on screen
      (battery-check "and kept when it is entered"
                     (and (not (active-minibuffer-window))
                          (equal canvas-minimap-viewport-color "#00ff00")
                          (window-live-p (get-buffer-window transient--buffer-name)))
                     (format "colour %S, menu %s" canvas-minimap-viewport-color
                             (cond ((window-live-p (get-buffer-window transient--buffer-name)) "shown")
                                   (transient--prefix "active but hidden")
                                   (t "gone")))))
    ;; GIVEN a completion UI that keeps a current candidate, icomplete
    ;; being the one built in, AND the tint still at full strength
    ;; WHEN the candidates at the colour prompt are stepped through
    ;; THEN the band takes each one's colour as it comes up, before any
    ;; of them is entered
    (icomplete-mode 1)
    ;; icomplete sits out keyboard macros, so the probe steps for it,
    ;; after taking its reading.
    (battery-probe-with
     (lambda () (let* ((st (battery-state))
                       (band (battery-deco-slots st 1))
                       (mid (nth (/ (length band) 2) band)))
                  (prog1 (list (car (completion-all-sorted-completions))
                               canvas-minimap-viewport-color
                               (and mid (battery-pixel st mid 1 20)))
                    (icomplete-forward-completions)))))
    (condition-case nil
        (execute-kbd-macro (kbd "v c b l u e <f9> <f9> <f9> C-g"))
      (quit nil))
    (icomplete-mode -1)
    (pcase-let ((`((,cand3 ,colour3 ,pixel3) (,cand2 ,colour2 ,pixel2) ,_) battery-probed))
      (cl-flet ((argb (name) (and (stringp name)
                                  (apply #'canvas-minimap--argb (canvas-minimap--rgb name)))))
        (battery-check "a candidate is drawn as it is stepped on to"
                       (and (stringp cand2) (stringp cand3) (not (equal cand2 cand3))
                            (equal colour2 cand2) (equal colour3 cand3)
                            (eql pixel2 (argb cand2)) (eql pixel3 (argb cand3)))
                       (format "%S then %S; drawn %S then %S" cand2 cand3 colour2 colour3))))
    (setq canvas-minimap-viewport-color nil
          canvas-minimap-viewport-alpha 0.22)
    (execute-kbd-macro (kbd "q")))

  (battery-step 0.4
    ;; WHEN the mode is turned off
    (canvas-minimap-mode -1)
    (setq battery-left-behind
          (cons (length (canvas-minimap--windows (selected-frame)))
                (hash-table-count canvas-minimap--states)))
    ;; WHEN it is turned on again
    (canvas-minimap-mode 1)
    (canvas-minimap--update)
    (canvas-minimap--update))
  (battery-step 0.5
    ;; THEN it left no window and no drawing of one behind, and a map is
    ;; up again, drawing the buffer
    (let ((st (battery-state)))
      (battery-check "the mode goes off and comes back"
                     (and (equal battery-left-behind '(0 . 0))
                          (canvas-minimap--state-p st)
                          (window-live-p (canvas-minimap--state-window st))
                          (eq (canvas-minimap--state-buffer st) battery-src))
                     (format "off left %S windows and %S states"
                             (car battery-left-behind) (cdr battery-left-behind)))))

  (battery-step 0.5
    ;; GIVEN a running map, whose state was laid out by the definitions
    ;; the file on disk holds
    ;; WHEN the file is loaded again, as it is while working on it
    ;; THEN the states from before are dropped AND the map draws itself
    ;; anew rather than reading the old ones through the new definitions
    (battery-check "reloading over a running map is safe"
                   (condition-case err
                       (progn
                         (load (expand-file-name "canvas-minimap.el" battery-root)
                               nil t)
                         (and (zerop (hash-table-count canvas-minimap--states))
                              (progn
                                (canvas-minimap--update)
                                (canvas-minimap--update)
                                (canvas-minimap--state-p (battery-state)))))
                     (error (battery-say "   %S" err) nil))))

  (battery-step 0.5
    ;; Markdown's view mode appends an image below a link using an
    ;; after-string.  Exercise actual canvas pixels and click coordinates.
    (let* ((buf (get-buffer-create "appended-image.txt"))
           (png (expand-file-name "images/splash.png" data-directory))
           (img (create-image png nil nil :height 100 :scale 1))
           (canvas-minimap-smooth-scroll nil)
           (canvas-minimap-thumbnail-functions
            (list (lambda (_img w h _bg) (make-vector (* w h) #xFF12AB34)))))
      (switch-to-buffer buf)
      (erase-buffer)
      (insert "![preview](splash.png)\nnext line\n")
      (goto-char (point-min))
      (let ((ov (make-overlay (1- (line-end-position)) (line-end-position))))
        (overlay-put ov 'after-string (concat "\n" (propertize " " 'display img))))
      (redisplay t)
      (canvas-minimap-refresh)
      (canvas-minimap--update)
      (let* ((st (battery-state))
             (picture (canvas-minimap--picture-of st (point-min)))
             (x (canvas-minimap--state-text-x0 st))
             (y (canvas-minimap--slot-y st 1))
             (width (canvas-minimap--state-width st)))
        ;; Remove viewport decorations before inspecting base pixels.
        (canvas-minimap--undecorate-all st)
        (battery-check "an appended image keeps its link row"
                       (and (equal (nth 2 picture) 1)
                            (equal (aref (canvas-minimap--state-cookies st)
                                         (nth 1 picture)) 2)))
        (battery-check "an after-string thumbnail reaches the canvas"
                       (= (aref (canvas-minimap--state-data st) (+ (* y width) x))
                          #xFF12AB34))
        (battery-check "the link row is not a picture click"
                       (not (canvas-minimap--picture-at
                             st x (canvas-minimap--slot-y st 0))))
        (battery-check "appended image clicks start below the link"
                       (equal (canvas-minimap--picture-at st x y)
                              (list img 0.0 0.0))))))

  (setq battery-steps (nreverse battery-steps))
  (battery-run))

(run-at-time 120 nil (lambda () (battery-say "TIMEOUT") (kill-emacs 100)))

;;; battery.el ends here
