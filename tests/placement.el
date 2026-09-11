;;; placement.el --- Batch checks for where the map's slice starts -*- lexical-binding: t; -*-

;; Like tests/guards.el these run headless, and need no canvas:
;;
;;     emacs -batch -Q -l tests/placement.el -f ert-run-tests-batch-and-exit
;;
;; They cover `free' scrolling, where the map stays where it is while
;; the band moves over it and moves only when the band would leave it,
;; and `middle' scrolling, where the band stays in the middle of the map
;; wherever the buffer allows.  The rules are worked out in buffer lines,
;; so they can be checked without drawing.

;;; Code:

(require 'ert)

(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  ;; The source, not a compiled file beside it that may be older.
  (load (expand-file-name "../canvas-minimap.el" here) nil t))

(defmacro canvas-minimap-test-with-lines (n &rest body)
  "Run BODY in a buffer of N numbered lines, each ended by a newline."
  (declare (indent 1))
  `(with-temp-buffer
     (dotimes (i ,n) (insert (format "line %d\n" (1+ i))))
     ,@body))

(defun canvas-minimap-test-fold (from to)
  "Hide buffer lines FROM to TO, the way a folded outline does."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- from))
    (let ((beg (point)))
      (forward-line (1+ (- to from)))
      (put-text-property beg (point) 'invisible t))))

(ert-deftest canvas-minimap-free-leaves-a-band-on-the-map-alone ()
  "GIVEN a 20-row map starting at line 50 of 200
WHEN the window shows lines 55 to 60, all of them on the map
THEN the map stays where it is."
  (canvas-minimap-test-with-lines 200
    (should (= 50 (canvas-minimap--free-start 50 20 55 60)))))

(ert-deftest canvas-minimap-free-follows-a-band-over-the-top-edge ()
  "GIVEN a 20-row map starting at line 50
WHEN the window moves up to lines 45 to 52, partly off the top
THEN the map moves up just far enough to start on the window's first
line."
  (canvas-minimap-test-with-lines 200
    (should (= 45 (canvas-minimap--free-start 50 20 45 52)))))

(ert-deftest canvas-minimap-free-follows-a-band-over-the-bottom-edge ()
  "GIVEN a 20-row map starting at line 50, so its last row is line 69
WHEN the window moves down to lines 65 to 72, partly off the bottom
THEN the map moves down just far enough to end on the window's last
line, which puts line 72 on row 20."
  (canvas-minimap-test-with-lines 200
    (should (= 53 (canvas-minimap--free-start 50 20 65 72)))))

(ert-deftest canvas-minimap-free-centres-a-band-that-lands-below-the-map ()
  "GIVEN a 20-row map starting at line 50
WHEN the window jumps down to lines 100 to 105, nowhere on the map
THEN the map puts those six lines in its middle, with seven rows above
them and seven below."
  (canvas-minimap-test-with-lines 200
    (should (= 93 (canvas-minimap--free-start 50 20 100 105)))))

(ert-deftest canvas-minimap-free-centres-a-band-that-lands-above-the-map ()
  "GIVEN a 20-row map starting at line 50
WHEN the window jumps up to lines 10 to 15, nowhere on the map
THEN the map puts those six lines in its middle."
  (canvas-minimap-test-with-lines 200
    (should (= 3 (canvas-minimap--free-start 50 20 10 15)))))

(ert-deftest canvas-minimap-free-shows-a-tall-band-from-its-top ()
  "GIVEN a 20-row map
WHEN the window shows 31 lines, more than the map has rows
THEN the map starts on the window's first line."
  (canvas-minimap-test-with-lines 200
    (should (= 60 (canvas-minimap--free-start 50 20 60 90)))))

(ert-deftest canvas-minimap-free-never-leaves-rows-under-the-last-line ()
  "GIVEN a 20-row map over 200 lines
WHEN the window jumps to lines 190 to 195, where centring them would
leave the map's last rows under the end of the buffer
THEN the map stops with line 200 on its last row."
  (canvas-minimap-test-with-lines 200
    (should (= 181 (canvas-minimap--free-start 50 20 190 195)))))

(ert-deftest canvas-minimap-free-counts-only-the-lines-it-draws ()
  "GIVEN a 20-row map starting at line 50, with lines 60 to 89 folded
WHEN the window shows lines 90 to 94, 44 buffer lines below the map's
first line
THEN the map stays: folded lines take no rows, so those lines sit on
rows 11 to 15."
  (canvas-minimap-test-with-lines 200
    (canvas-minimap-test-fold 60 89)
    (should (= 50 (canvas-minimap--free-start 50 20 90 94)))))

(ert-deftest canvas-minimap-middle-centres-the-band ()
  "GIVEN a 20-row map over 200 lines
WHEN the window shows lines 100 to 105
THEN the map puts those six lines in its middle, with seven rows above
them and seven below."
  (canvas-minimap-test-with-lines 200
    (should (= 93 (canvas-minimap--middle-start 20 100 105)))))

(ert-deftest canvas-minimap-middle-stops-at-the-first-line ()
  "GIVEN a 20-row map over 200 lines
WHEN the window shows lines 3 to 8, too near the start to centre
THEN the map starts on line 1, as near the middle as the buffer lets
the band go."
  (canvas-minimap-test-with-lines 200
    (should (= 1 (canvas-minimap--middle-start 20 3 8)))))

(ert-deftest canvas-minimap-middle-stops-at-the-last-line ()
  "GIVEN a 20-row map over 200 lines
WHEN the window shows lines 195 to 200, too near the end to centre
THEN the map ends with line 200 on its last row."
  (canvas-minimap-test-with-lines 200
    (should (= 181 (canvas-minimap--middle-start 20 195 200)))))

(ert-deftest canvas-minimap-middle-shows-a-tall-band-from-its-top ()
  "GIVEN a 20-row map
WHEN the window shows 31 lines, more than the map has rows
THEN the map starts on the window's first line."
  (canvas-minimap-test-with-lines 200
    (should (= 60 (canvas-minimap--middle-start 20 60 90)))))

(defun canvas-minimap-test-picture (line rows)
  "A row counter for a buffer whose LINE stands ROWS rows tall."
  (lambda () (if (= (line-number-at-pos) line) rows 1)))

(ert-deftest canvas-minimap-free-counts-a-picture-as-its-rows ()
  "GIVEN a 20-row free map starting at line 50, with a picture on line
55 that stands 15 rows tall
WHEN the window shows lines 60 to 65, which would be on the map if the
picture took one row, but are off it
THEN the map moves to take the window's lines in, as far into the
middle as the picture lets it."
  (canvas-minimap-test-with-lines 200
    (should (= 56 (canvas-minimap--free-start
                   50 20 60 65 (canvas-minimap-test-picture 55 15))))))

(ert-deftest canvas-minimap-middle-counts-a-picture-as-its-rows ()
  "GIVEN a 20-row middle map, with a picture on line 95 that stands 5
rows tall
WHEN the window shows lines 100 to 105
THEN the seven rows above the band hold lines 96 to 99 and nothing of
the picture: a picture is not split to fill the rows."
  (canvas-minimap-test-with-lines 200
    (should (= 96 (canvas-minimap--middle-start
                   20 100 105 (canvas-minimap-test-picture 95 5))))))

;;; placement.el ends here
