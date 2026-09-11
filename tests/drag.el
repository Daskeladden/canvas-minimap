;;; drag.el --- Batch checks for dragging the map against an edge -*- lexical-binding: t; -*-

;; Like tests/guards.el these run headless, and need no canvas:
;;
;;     emacs -batch -Q -l tests/drag.el -f ert-run-tests-batch-and-exit
;;
;; They cover scrolling on while the pointer is held at the top or
;; bottom of the map: which pointer positions count as an edge, how fast
;; the window moves the longer the pointer stays there, that the speed
;; is kept by the clock rather than by how long each step takes, and
;; when the pointer's move scrubs the window to the line under it.

;;; Code:

(require 'ert)
(require 'cl-lib)

(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  ;; The source, not a compiled file beside it that may be older.
  (load (expand-file-name "../canvas-minimap.el" here) nil t))

(defun canvas-minimap-test--map (rows top)
  "A map state of ROWS five-pixel rows, drawn from pixel row TOP."
  (funcall 'canvas-minimap--state-create :rows rows :top top :lh 5 :scale 1))

(defun canvas-minimap-test--posn (window y)
  "A pointer position over the picture in WINDOW, Y pixels down."
  (list window 1 (cons 10 y) 0 nil 1 (cons 0 0) nil (cons 10 y) (cons 10 10)))

(ert-deftest canvas-minimap-edge-is-the-first-and-last-row ()
  "GIVEN a map of 100 rows, five pixels each
WHEN the pointer is on its first row, its last row, or between them
THEN the first row is the top edge, the last row is the bottom edge,
and the rows between are no edge at all."
  (let ((st (canvas-minimap-test--map 100 0)))
    (should (eq 'up (canvas-minimap--edge-at st 2)))
    (should (eq 'down (canvas-minimap--edge-at st 497)))
    (should-not (canvas-minimap--edge-at st 250))
    (should-not (canvas-minimap--edge-at st 7))))

(ert-deftest canvas-minimap-edge-reaches-past-the-map ()
  "GIVEN a map of 100 rows drawn below a 40-pixel layout strip
WHEN the pointer is over the strip, above the window, or below the map
THEN each counts as the edge it is past."
  (let ((st (canvas-minimap-test--map 100 40)))
    (should (eq 'up (canvas-minimap--edge-at st 20)))
    (should (eq 'up (canvas-minimap--edge-at st -30)))
    (should (eq 'down (canvas-minimap--edge-at st 900)))))

(ert-deftest canvas-minimap-edge-speed-gathers-with-time-held ()
  "GIVEN a window showing 44 lines
WHEN the pointer is held at an edge for a first second, and then a second
one
THEN the scrolling starts at 20 lines a second and gains 200 a second:
120 lines in the first second, 320 in the next."
  (should (= 120 (canvas-minimap--edge-distance 0 1 44)))
  (should (= 320 (canvas-minimap--edge-distance 1 2 44))))

(ert-deftest canvas-minimap-edge-speed-for-an-unmeasured-window ()
  "GIVEN a window whose height has not been measured yet
WHEN the pointer is held at an edge however long
THEN it scrolls at the starting speed, 20 lines a second."
  (should (< (abs (- 20 (canvas-minimap--edge-distance 30 31 nil))) 1e-6)))

(ert-deftest canvas-minimap-edge-distance-follows-the-time-held ()
  "GIVEN a window showing 44 lines, held at an edge for half a second
WHEN that half second is scrolled in eight steps on time, or in one late
step
THEN both come to the 35 lines the speed curve earns over it: a late
step moves no further, and no less far, than the time allows."
  (let ((carry 0.0) (lines 0))
    (dotimes (i 8)
      (let ((step (canvas-minimap--edge-advance
                   (canvas-minimap--edge-distance (* i 0.0625) (* (1+ i) 0.0625) 44)
                   carry)))
        (setq lines (+ lines (car step)) carry (cdr step))))
    (should (= 35 lines))
    (should (= 35 (car (canvas-minimap--edge-advance
                        (canvas-minimap--edge-distance 0 0.5 44) 0.0))))))

(ert-deftest canvas-minimap-edge-distance-keeps-to-the-cap ()
  "GIVEN a window showing 44 lines
WHEN a second is scrolled long after the speed reached its cap, and
another second is scrolled across the moment it does, at 4.3 seconds
THEN the first moves 880 lines, a window every step interval, and the
second counts the speeding up and the cap each for its own part."
  (should (< (abs (- 880 (canvas-minimap--edge-distance 100 101 44))) 1e-6))
  (should (< (abs (- 871 (canvas-minimap--edge-distance 4 5 44))) 1e-6)))

(ert-deftest canvas-minimap-edge-step-keeps-part-lines ()
  "GIVEN steps that each earn half a line
WHEN two of them come in turn
THEN the second moves a line, where rounding would move none."
  (let* ((a (canvas-minimap--edge-advance 0.5 0.0))
         (b (canvas-minimap--edge-advance 0.5 (cdr a))))
    (should (= 0 (car a)))
    (should (= 1 (car b)))))

(ert-deftest canvas-minimap-edge-steps-keep-to-the-clock ()
  "GIVEN an edge step that began at second 10
WHEN the loop asks how long to wait for the next, 20 ms and 80 ms later
THEN it waits out the rest of the interval, and only a moment once the
next step is overdue."
  (should (< (abs (- (canvas-minimap--edge-wait 10.0 10.02) 0.03)) 1e-9))
  (should (< 0 (canvas-minimap--edge-wait 10.0 10.08) 0.002)))

(ert-deftest canvas-minimap-drag-scrubs-on-reaching-the-other-edge ()
  "GIVEN a drag held at the top edge of a 100-row map
WHEN the pointer jumps straight to its bottom row
THEN the window is scrubbed to the line there first, and the bottom is
the edge held from then on."
  (let ((st (canvas-minimap-test--map 100 0))
        (scrubbed 0))
    (cl-letf (((symbol-function 'canvas-minimap--posn-y)
               (lambda (posn _) (cdr (posn-x-y posn))))
              ((symbol-function 'canvas-minimap--drag-step)
               (lambda (&rest _) (setq scrubbed (1+ scrubbed)))))
      (should (eq 'down (canvas-minimap--drag-motion
                         st 'map (canvas-minimap-test--posn 'map 497) 'up)))
      (should (= 1 scrubbed)))))

(ert-deftest canvas-minimap-drag-held-at-an-edge-scrubs-no-more ()
  "GIVEN a drag held at the bottom edge of a 100-row map
WHEN the pointer moves along that edge
THEN the held edge goes on scrolling, and the window is not scrubbed."
  (let ((st (canvas-minimap-test--map 100 0))
        (scrubbed 0))
    (cl-letf (((symbol-function 'canvas-minimap--posn-y)
               (lambda (posn _) (cdr (posn-x-y posn))))
              ((symbol-function 'canvas-minimap--drag-step)
               (lambda (&rest _) (setq scrubbed (1+ scrubbed)))))
      (should (eq 'down (canvas-minimap--drag-motion
                         st 'map (canvas-minimap-test--posn 'map 497) 'down)))
      (should (= 0 scrubbed)))))

;;; drag.el ends here
