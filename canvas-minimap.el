;;; canvas-minimap.el --- Pixel minimap drawn on a canvas -*- lexical-binding: t -*-

;; Copyright (C) 2026 canvas-minimap contributors

;; Author: Daskeladden
;; Version: 0.1.0
;; Package-Requires: ((emacs "32.0.50") (transient "0.7.0"))
;; Keywords: convenience, frames
;; URL: https://github.com/Daskeladden/canvas-minimap

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A Sublime-style minimap: a downsampled pixel picture of the buffer,
;; shown in a side window and drawn with the Emacs 32 canvas image type.
;;
;; Nothing here is a second buffer at a one-point font.  The minimap is
;; literally a pixel buffer: a shape per character, coloured by the face
;; at that position, and a downsampled picture where the buffer shows an
;; image.  Because a canvas keeps its pixels across refreshes, the work
;; is incremental: editing a line repaints that line's few pixel rows,
;; scrolling shifts rows within the buffer and rasterizes only the lines
;; that came into view, and moving point repaints nothing but the
;; viewport tint.
;;
;; `canvas-minimap-layout-height' puts a plan of the frame's windows
;; across the top, with the one the map is drawing filled in, since a
;; map otherwise says nothing about which window it belongs to.
;; Clicking a pane goes to that window, and with `ace-window' loaded
;; each one carries the key that would.
;;
;; A jump across the buffer is glided to rather than cut to, so the map
;; arrives from the direction the jump went rather than being replaced
;; in a single frame.
;;
;; While `consult-line' or one of its relatives is reading from the
;; minibuffer, the lines its input matches are marked on the map, so a
;; search has a shape before any of it is jumped to.
;;
;; Enable with `canvas-minimap-mode'.  GUI-only; silently inert on
;; terminals and Emacsen built without canvas support.
;;
;; `canvas-minimap-menu' lays every option out in a transient menu, and
;; draws each change as it is made -- a value typed at a prompt as it
;; is typed -- so a setting can be seen before it is kept.  An option
;; that another one has switched off is dimmed, with that as the reason.

;;; Code:

(require 'cl-lib)
(require 'transient)

(defgroup canvas-minimap nil
  "Pixel minimap drawn on a canvas image."
  :group 'convenience
  :prefix "canvas-minimap-")

;;;; Options

(defcustom canvas-minimap-width 110
  "Width of the minimap window, in pixels.
Changing this takes effect on the next refresh: the window is resized
to match and the canvas is rebuilt at the new size.  See also
`canvas-minimap-set-width', `canvas-minimap-widen' and
`canvas-minimap-narrow', which do it interactively."
  :type 'integer)

(defcustom canvas-minimap-line-height 3
  "Height of one buffer line in the minimap, in pixels.
Includes `canvas-minimap-line-gap'.  Three ink rows is what
`canvas-minimap-glyph-detail' wants -- one per glyph zone -- so the
default spends all three on ink and leaves no gap.  A height of 4 with a
gap of 1 separates the lines instead, for a quarter fewer of them on
screen."
  :type 'integer)

(defcustom canvas-minimap-line-gap 0
  "Blank pixel rows left below each line, for legibility.
Must be smaller than `canvas-minimap-line-height'.  With glyph detail on
the rows separate themselves -- ascenders and descenders are lighter
than the x-height band -- so a gap is usually wasted height."
  :type 'integer)

(defcustom canvas-minimap-column-width 1
  "Width of one buffer column in the minimap, in pixels."
  :type 'integer)

(defcustom canvas-minimap-glyph-auto-generate t
  "When non-nil, rasterize a glyph table for the frame's own font.
The table shipped with the package was taken from one font; a buffer in
any other one is drawn with the wrong letterforms until a table for it
exists.  Generating one needs `fc-match' and a python3 with Pillow, runs
in the background, and is cached under `canvas-minimap-glyph-directory'
so it happens once per font.  Without those, or with this off, the
shipped table is used for everything."
  :type 'boolean)

(defcustom canvas-minimap-glyph-directory
  (locate-user-emacs-file "canvas-minimap-glyphs/")
  "Where generated glyph tables are cached."
  :type 'directory)

(defcustom canvas-minimap-device-scale 'auto
  "Canvas pixels per window pixel.
`auto' follows the frame's scale factor, so where Emacs would magnify an
image to fill a HiDPI pixel grid the minimap is drawn on that grid
instead and shown scaled back down.  Every other length here stays in
window pixels; this only decides how finely they are drawn."
  :type '(choice (const :tag "Follow the frame" auto) number))

(defcustom canvas-minimap-width-step 20
  "Pixels `canvas-minimap-widen' and `canvas-minimap-narrow' move by."
  :type 'integer)

(defcustom canvas-minimap-gutter-width 3
  "Width of the fringe strip beside the minimap, in pixels.
Set to 0 to give the whole canvas over to text."
  :type 'integer)

(defcustom canvas-minimap-gutter-side 'left
  "Edge of the minimap the fringe strip sits on."
  :type '(choice (const left) (const right)))

(defcustom canvas-minimap-placement 'frame
  "Where minimaps live.

`frame'   One per frame, on its edge, showing whichever window is
          selected.  Costs the same screen space however many windows
          there are.
`window'  One per window, on that window's own edge, the way an editor
          with panes does it.

Under `window', a window that could not keep
`canvas-minimap-min-window-width' columns beside a minimap does without
one, so splitting on down to slivers does not fill the frame with them."
  :type '(choice (const :tag "One per frame" frame)
                 (const :tag "One per window" window)))

(defcustom canvas-minimap-min-window-width 72
  "Columns a window must keep beside its own minimap to be given one.
Only consulted when `canvas-minimap-placement' is `window'."
  :type 'integer)

(defcustom canvas-minimap-side 'right
  "Side of the frame the minimap window appears on."
  :type '(choice (const left) (const right)))

(defcustom canvas-minimap-ink 0.9
  "How strongly glyph colour shows against the background (0..1).
Below 1 the picture reads as a texture rather than as unreadable text."
  :type 'float)

(defcustom canvas-minimap-glyph-detail t
  "When non-nil, draw each character from its own shape.
The shapes come from a table rasterized from a real font ahead of time
and averaged down to the cell the map has: a comma marks the baseline
faintly, a quote marks the top, `#\=' fills its cell, and ascenders and
descenders reach out of the x-height band.  Text then reads as text
rather than as a solid bar.

Set to nil for the cheaper flat look, where every non-blank character
is one solid block."
  :type 'boolean)

(defcustom canvas-minimap-viewport-color nil
  "Colour of the viewport highlight, or nil for the `region' background."
  :type '(choice (const :tag "Region background" nil) color))

(defcustom canvas-minimap-viewport-alpha 0.22
  "Strength of the viewport highlight (0..1)."
  :type 'float)

(defcustom canvas-minimap-viewport-style 'tint
  "How the lines the window is showing are marked on the map.
`tint' colours them over, `outline' draws a line around them and leaves
the map\'s own background inside, and `both' does the two together."
  :type '(choice (const :tag "Tint the rows" tint)
                 (const :tag "Draw a line round them" outline)
                 (const :tag "Both" both)))

(defcustom canvas-minimap-viewport-outline-color nil
  "Colour of the line drawn round the viewport, or nil for a dim one.
Nil is a mix of the map\'s background and foreground, which is what the
rest of the map outlines things with."
  :type '(choice (const :tag "A dim outline" nil) color))

(defcustom canvas-minimap-point-color nil
  "Colour of the point marker, or nil for the frame's cursor colour."
  :type '(choice (const :tag "Cursor colour" nil) color))

(defcustom canvas-minimap-show-point t
  "When non-nil, mark the line point is on."
  :type 'boolean)

(defcustom canvas-minimap-point-defer t
  "When non-nil, drop the point marker if the line is already highlighted.
`hl-line' and friends already say where point is, in their own colour.
Painting a marker over that says it again in the wrong one."
  :type 'boolean)

(defcustom canvas-minimap-point-height 1
  "Height of the point marker, in pixels.
Kept thinner than a line on purpose: a marker as tall as the line
paints over whatever is on it, which hides exactly the highlighting --
a pulse, a region -- you are most likely to be looking for."
  :type 'integer)

(defcustom canvas-minimap-image-thumbnails t
  "When non-nil, draw a picture of an image rather than a plain block.
`tools/gen-image-thumb.py' downsamples the file in the background, the
way glyph tables are made, and the answer is kept for the rest of the
session.  Needs a python3 with Pillow; without one the block stays
plain, which still says where the picture is and how much room it
takes."
  :type 'boolean)

(defcustom canvas-minimap-layout-height nil
  "Height of the layout strip at the top of the minimap, in pixels.
Nil, the default, leaves it out: the rows it would take are rows of
buffer, and a map of one window has nothing to say that its own picture
does not.

Set it and the top of the map becomes a plan of the frame's windows,
with the one the map is drawing filled in and the rest as outlines.  A
map says a great deal about where you are in a buffer and nothing at
all about which of a frame's windows it belongs to, which is the one
thing a picture answers instantly.  `auto' is a quarter of the map's
width, which keeps the plan in proportion whatever
`canvas-minimap-width' is set to.  Even then the strip waits for the
frame to be split, unless `canvas-minimap-layout-always' says not to."
  :type '(choice (const :tag "No layout strip" nil)
                 (const :tag "A quarter of the width" auto)
                 integer))

(defcustom canvas-minimap-layout-always nil
  "When non-nil, draw the layout strip for a frame with one window too.
By default the strip waits for a split: a plan of one window is a box
with nothing to tell apart, and its rows are better spent on the
buffer.  Only matters while `canvas-minimap-layout-height' has the
strip on at all."
  :type 'boolean)

(defcustom canvas-minimap-layout-labels t
  "When non-nil, label each pane of the layout strip with its window's key.
The key is the one `ace-window' would select that window with, so the
plan says not only where a pane is but what to press to get there.

ace-window is asked for once when the first plan is drawn, since it is
usually autoloaded and its keys cannot be read before it is there.
Nothing is drawn if it is not installed, or when it would be asking for
more than one key per window."
  :type 'boolean)

(defcustom canvas-minimap-layout-color nil
  "Colour filling the current window in the layout strip.
Nil follows `canvas-minimap-point-color', the frame's cursor colour, so
the pane you are in and the line you are on are marked in one colour --
and a cursor is the one colour a theme has to keep visible.  How
strongly it covers is `canvas-minimap-layout-alpha'."
  :type '(choice (const :tag "From the point marker" nil) color))

(defcustom canvas-minimap-layout-alpha 0.55
  "How strongly `canvas-minimap-layout-color' fills its pane (0..1).
Which pane is current is carried by its being filled at all rather than
by how brightly, so this does not have to be loud: a cursor colour laid
on at full strength is a white block on a dark theme, which is a lot of
light for a fact the shape has already told you."
  :type 'float)

(defcustom canvas-minimap-layout-outline-color nil
  "Colour of the other windows' outlines in the layout strip, used as given.
Nil is the default foreground, a bit over a third of the way from the
background."
  :type '(choice (const :tag "From the default foreground" nil) color))

(defcustom canvas-minimap-layout-background nil
  "Colour behind the layout strip, used as given.
Nil is the minimap's own background, which leaves the plan floating
over the map rather than sitting in a band of its own."
  :type '(choice (const :tag "The minimap background" nil) color))

(defcustom canvas-minimap-smooth-scroll t
  "When non-nil, glide the minimap to a new position rather than jumping.
A jump across the buffer -- `consult-line', imenu, an xref,
`end-of-buffer' -- moves the map by most of its height at once, and a
picture that is replaced in a single frame says nothing about where it
went.  Drawing the lines in between says it: the map arrives from the
direction the jump took, and how long it takes to arrive is how far it
came.

Only the map moves.  The buffer is already where the jump put it, and
scrubbing the map with the mouse never glides -- the map has to stay
under the pointer."
  :type 'boolean)

(defcustom canvas-minimap-smooth-scroll-interval 0.025
  "Seconds between frames of a glide."
  :type 'number)

(defcustom canvas-minimap-smooth-scroll-step 0.5
  "Fraction of what is left of a glide that one frame covers.
Half of the remainder each frame leaves fast and settles slowly, which
is what makes the arrival readable rather than merely fast.  A smaller
fraction is a longer, more even glide."
  :type 'float)

(defcustom canvas-minimap-smooth-scroll-threshold 10
  "Shortest move worth gliding, in lines; shorter ones are drawn outright.
Ordinary scrolling walks the slice a line or two at a time and is
smooth already.  Animating that would only put the map behind the
window it is meant to be showing."
  :type 'integer)

(defcustom canvas-minimap-smooth-scroll-distance 500
  "Longest glide, in lines.
A jump further than this comes in from this far out instead of from
where the map was, so a glide costs the same however far you went --
and half a buffer going past in a fifth of a second reads as a blur
whether it is drawn or not."
  :type 'integer)

(defcustom canvas-minimap-highlight-matches t
  "When non-nil, mark the lines an active completion is matching.
`consult-line' and its relatives never touch the buffer: the lines
they are matching exist only as candidates in a minibuffer, so the
buffer they came from shows nothing at all until one is jumped to.
Marking them puts the shape of a search back on the map -- where the
hits cluster, and how much of the file is between them -- while the
input is still being typed."
  :type 'boolean)

(defcustom canvas-minimap-match-color nil
  "Colour matched lines are tinted with, or nil for `lazy-highlight'.
That face is what an isearch paints the matches it is not on with,
which is what these are."
  :type '(choice (const :tag "Lazy highlight background" nil) color))

(defcustom canvas-minimap-match-alpha 0.5
  "Strength of the match highlight (0..1)."
  :type 'float)

(defcustom canvas-minimap-match-limit 2000
  "Most matches worth marking; past this nothing is.
One character matches most of a buffer, and a map tinted end to end
says no more than a bare one does.  Rather than draw that, the marks
stay off until the input has narrowed things down enough to mean
something."
  :type 'integer)

(defcustom canvas-minimap-poll-interval 0.1
  "Seconds between checks for highlighting that changed on its own.
Overlays other packages put on the buffer -- a pulse fading out, a
symbol highlight, a linter's marks arriving -- change no text, so
nothing marks the affected lines stale, and some of them are driven by
a timer with no command in sight for a hook to hang off.

Set to nil to refresh only on commands, at the cost of missing those."
  :type '(choice (const :tag "Only on commands" nil) number))

(defcustom canvas-minimap-update-delay 0.04
  "Idle delay before the minimap is brought up to date, in seconds."
  :type 'number)

(defcustom canvas-minimap-exclude-modes
  '(image-mode doc-view-mode pdf-view-mode vterm-mode term-mode)
  "Major modes for which no minimap is shown."
  :type '(repeat symbol))

;;;; Colour

(defun canvas-minimap--rgb (color)
  "Return COLOR as a list of three 0-255 integers, or nil."
  (when (and color (stringp color))
    (let ((v (ignore-errors (color-values color))))
      (when v (mapcar (lambda (c) (ash c -8)) v)))))

(defsubst canvas-minimap--argb (r g b)
  "Pack R, G and B (0-255) into an opaque ARGB32 fixnum."
  (logior #xFF000000 (ash r 16) (ash g 8) b))

(defun canvas-minimap--face-attr (spec attr &optional seen)
  "Return ATTR as specified by face SPEC, or nil.
SPEC is whatever a `face' text or overlay property holds: a face symbol,
an anonymous attribute plist, a legacy colour cons, or a list of any of
those.  The first face in a list that specifies ATTR wins, which is how
the display merges them.

A face name is looked up through the buffer's `face-remapping-alist'
first, because a name is not the whole story about how a face is drawn:
`lin' leaves `hl-line' on the overlay and remaps the face buffer-locally,
so reading the face's own attributes reports a colour the buffer never
shows.  SEEN carries the names already remapped, since a remapping
commonly lists the original face among its replacements.

Callers must run in the buffer being drawn; `face-remapping-alist' is
buffer-local."
  (cond
   ((null spec) nil)
   ((symbolp spec)
    (let ((remap (and (not (memq spec seen))
                      (assq spec face-remapping-alist))))
      (if remap
          (canvas-minimap--face-attr (cdr remap) attr (cons spec seen))
        (when (facep spec)
          (let ((v (face-attribute spec attr nil t)))
            (unless (memq v '(nil unspecified)) v))))))
   ((stringp spec)
    (let ((s (intern-soft spec)))
      (and s (canvas-minimap--face-attr s attr seen))))
   ((keywordp (car-safe spec))
    (let ((v (plist-get spec attr)))
      (if (and v (not (eq v 'unspecified)))
          v
        (canvas-minimap--face-attr (plist-get spec :inherit) attr seen))))
   ((and (eq (car-safe spec) 'foreground-color) (eq attr :foreground)) (cdr spec))
   ((and (eq (car-safe spec) 'background-color) (eq attr :background)) (cdr spec))
   ((consp spec)
    (let ((l spec) res)
      (while (and (consp l) (not res))
        (setq res (canvas-minimap--face-attr (car l) attr seen)
              l (cdr l)))
      res))))

(defconst canvas-minimap--gamma 2.2
  "Gamma for perceptually even blending of partial glyph coverage.")

(defun canvas-minimap--make-lut (bg fg)
  "Build a 16-entry ARGB table blending FG over BG at coverage L/15.
Blending happens in linear light, which is what keeps a faint comma from
looking like grime while a dense `#\=' still reads as solid."
  (let ((lut (make-vector 16 0))
        (g canvas-minimap--gamma)
        (ink (min 1.0 (max 0.0 canvas-minimap-ink))))
    (dotimes (lvl 16)
      (let ((f (* ink (/ lvl 15.0)))
            (px #xFF000000))
        (dotimes (ch 3)
          (let* ((lin-bg (expt (/ (nth ch bg) 255.0) g))
                 (lin-fg (expt (/ (nth ch fg) 255.0) g))
                 (c (round (* 255.0 (expt (+ (* (- 1.0 f) lin-bg)
                                             (* f lin-fg))
                                          (/ 1.0 g))))))
            (setq px (logior px (ash (min 255 (max 0 c)) (* 8 (- 2 ch)))))))
        (aset lut lvl px)))
    lut))

;;;; Glyph density

;; Per character: how much ink covers each cell of an 8 by 24 grid, a hex
;; digit to a cell, rasterized from a real font by tools/gen-glyph-table.py.
;; The package averages that down to whatever cell it is drawing into,
;; which is close to what the font engine is doing at this size anyway.

(defconst canvas-minimap--glyph-width 8)
(defconst canvas-minimap--glyph-height 24)
(defconst canvas-minimap--glyph-first 32)

(defconst canvas-minimap--glyph-coverage
  (concat
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"  ; space
    "000000000000000000000000000000000000000000077000000ba000000ba000000ba000000a9000000a9000000a90000009900000098000000760000000000000076000001ff000000870000000000000000000000000000000000000000000"  ; !
    "000000000000000000000000000000000000000002a23a0002f34e0002f33e0002f23e0001f23e0001c22b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"  ; double quote
    "0000000000000000000000000000000000000000002702800059049000770670009508501ffffff703e43c4101e00d0002c00c0038c67d606ddcdec0086067000a4095000b20b300060061000000000000000000000000000000000000000000"  ; #
    "0000000000000000000330000006700000067000008ee80006ebbe600a8678b00b6673600a96700006fb700000afe7000007df50000679b0000674e00f2674e00c967aa005ffff30004ab3000006700000067000000000000000000000000000"  ; $
    "0000000000000000000000000000000000000000199100569cca00d2c43d0590c32d0c20b65c59006ff7c3000445a000000d3860005a9ee600d3d36a0590e14b0c20e25b4a00acd7520029810000000000000000000000000000000000000000"  ; %
    "0000000000000000000000000000000000000000007ca20005f9db0008a02f0008a0081004e1000000c900000bff30136e4ac0ab9801e7f3a7007f90a8005f608b01dae12fddc0c804a810370000000000000000000000000000000000000000"  ; &
    "000000000000000000000000000000000000000000077000000ba000000aa000000a9000000a90000008700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"  ; '
    "0000000000000000000000000000054000008f500006f600000e8000004f2000007c0000009a000000990000009900000099000000990000009a0000007c0000004f2000000d80000005f60000007f5000000430000000000000000000000000"  ; open paren
    "0000000000000000000000000540000007f70000007f50000009d0000002f2000000d5000000b7000000a7000000a7000000a7000000a7000000b7000000d5000003f2000009d000018f500007f6000004300000000000000000000000000000"  ; close paren
    "000000000000000000000000000000000000000000000000000000000007700000098000110980105e6877e42afeee92002ed100007cd50001e67c0006d01d400130030000000000000000000000000000000000000000000000000000000000"  ; *
    "0000000000000000000000000000000000000000000000000000000000000000000660000009900000099000044ba4402ffffff1033ba33000099000000990000008700000000000000000000000000000000000000000000000000000000000"  ; +
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000120000009d000000ba000000d8000000f5000002f2000001600000000000000000000"  ; ,
    "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000144440003ffff000133330000000000000000000000000000000000000000000000000000000000000000000000000000000000"  ; -
    "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000033000001fe000002ff100000870000000000000000000000000000000000000000000"  ; .
    "00000000000000000000000000000360000009a000000d5000002f1000006c000000a8000000e4000004f1000008c000000c7000001f3000005e000000aa000000e5000003f1000007c000000b70000008200000000000000000000000000000"  ; /
    "0000000000000000000000000000000000000000007cc60006faaf400b800aa00d3005c00e2005d00e2115d00e2cb5d00e2875d00e2005d00e2005d00d3006c00aa00b9004fddf20004993000000000000000000000000000000000000000000"  ; 0
    "00000000000000000000000000000000000000000019a00001cff10009e6f1000b33f1000103f1000003f1000003f1000003f1000003f1000003f1000003f1000003f1000beefee2068888810000000000000000000000000000000000000000"  ; 1
    "0000000000000000000000000000000000000000007cc60006faaf400b800a900d3006c0000007c000000a9000002e300000ca000007e200002f600001ca000008d100000dfeeed0068888700000000000000000000000000000000000000000"  ; 2
    "000000000000000000000000000000000000000008aaaa5009bbbf7000005e100002e500000ba000004fc4000029be2000000b80000007a0010007b00f2008a00c801d7007fcde10006a93000000000000000000000000000000000000000000"  ; 3
    "0000000000000000000000000000000000000000000076000002f4000008d000001e6000008d000000e7000006e10a700c700a701f100a701fccce7009999d7000000a7000000a70000005300000000000000000000000000000000000000000"  ; 4
    "000000000000000000000000000000000000000007aaaa400adbbb500a6000000a6000000a6000000adcb5000699bf3000000a90000007b0010006c00e3007b00c900c8006fcde20005a93000000000000000000000000000000000000000000"  ; 5
    "00000000000000000000000000000000000000000002a2000008c000000e6000006e100000c8000003f8830008fbbf400d8009b01f1004f02f0002f11f2004e00c900aa005fddf30004993000000000000000000000000000000000000000000"  ; 6
    "000000000000000000000000000000000000000009aaaaa20dcbbcf30d3004e10b3008a000000d6000002f1000006c000000b8000001f4000005f1000009b000000e6000003f2000003700000000000000000000000000000000000000000000"  ; 7
    "0000000000000000000000000000000000000000007cc60006faaf400b900a900c4007b00b6008a006d44e4000bff90008d45e600e4006d01f0003f01f1004f00c800ab006fddf40005994000000000000000000000000000000000000000000"  ; 8
    "0000000000000000000000000000000000000000007cc60007faaf500d7009c01f1003f02f0002f11f2004e00bb11ca003efff5000267e000000b9000003f3000009c000001e6000003710000000000000000000000000000000000000000000"  ; 9
    "000000000000000000000000000000000000000000000000000000000000000000088000002ff100000dc0000000000000000000000000000000000000000000000dc000002ff100000880000000000000000000000000000000000000000000"  ; :
    "000000000000000000000000000000000000000000000000000000000000000000088000003ff100001dc0000000000000000000000000000000000000012000000ac000000c9000000e7000001f4000003f1000002600000000000000000000"  ; semicolon
    "0000000000000000000000000000000000000000000000000000000000000010000006b00002bf60005ed30009e710000d5000000af80000007fc2000002be60000006b000000010000000000000000000000000000000000000000000000000"  ; <
    "000000000000000000000000000000000000000000000000000000000000000000000000056666500dffffc00222221000000000000000000ceeeeb0068888600000000000000000000000000000000000000000000000000000000000000000"  ; =
    "00000000000000000000000000000000000000000000000000000000000000000b50000008fa1000005ee40000019f70000007c000008f80002ce60007fa20000c50000001000000000000000000000000000000000000000000000000000000"  ; >
    "000000000000000000000000000000000000000003aa710003bcfa0000004f2000000c5000000c5000001e300028dc00005fa200005e000000390000000000000049100000bf4000005a10000000000000000000000000000000000000000000"  ; ?
    "0000000000000000000000000000000000000000007cc81007e87da00e4002f23d0000c55a0044b66906fdd6690c60d6690d40b6690d40b6690d40b6690b60d46904fdc05a0035102e0000000c90000004fdb800004ac9000000000000000000"  ; @
    "000000000000000000000000000000000000000000099000001ff100004de300007ab60000a7880000d55b0001f22e0004e00e1006d66e4009ffff700b7228a00e3005d02f0002f1270000820000000000000000000000000000000000000000"  ; A
    "000000000000000000000000000000000000000008aa94000bcbdf300b500b900b5007b00b5008a00b724e400bfff9000b734d600b5006c00b5003e00b5004e00b501bb00beeff30068873000000000000000000000000000000000000000000"  ; B
    "0000000000000000000000000000000000000000006cc60004fa9f5009a009a00b6004b00c5000000c5000000c5000000c5000000c5000000c5000000b6005d009b00aa003fdcf30004994000000000000000000000000000000000000000000"  ; C
    "000000000000000000000000000000000000000008aa92000ccbee100c501d700c5008a00c5007b00c5007b00c5007b00c5007b00c5007b00c5007b00c5008a00c502e600ceefc00068761000000000000000000000000000000000000000000"  ; D
    "000000000000000000000000000000000000000007aaaa800adbbb900a7000000a7000000a7000000a8222100affff500a8333100a7000000a7000000a7000000a7000000afeeec0058888600000000000000000000000000000000000000000"  ; E
    "000000000000000000000000000000000000000007aaaa900bdbbba00b5000000b5000000b5000000b5000000bdddd700bb888500b6000000b6000000b6000000b6000000b600000063000000000000000000000000000000000000000000000"  ; F
    "0000000000000000000000000000000000000000006cc60005faaf400a9009a00c5005a00c4000000c4000000c4277600c45ffc00c4005c00c4005c00c5006c009b00b9004fddf30004994000000000000000000000000000000000000000000"  ; G
    "0000000000000000000000000000000000000000084005700b5007a00b5007a00b5007a00b5007a00b5007a00bffffa00b955aa00b5007a00b5007a00b5007a00b5007a00b5007a0063004500000000000000000000000000000000000000000"  ; H
    "000000000000000000000000000000000000000006aaaa5007bedb60000a9000000a9000000a9000000a9000000a9000000a9000000a9000000a9000000a9000000a900009effe70058888400000000000000000000000000000000000000000"  ; I
    "00000000000000000000000000000000000000000000065000000a8000000a8000000a8000000a8000000a8000000a8000000a8000000a8013000a805c000b702f302e300afcec00017a81000000000000000000000000000000000000000000"  ; J
    "0000000000000000000000000000000000000000084002a10c5007c00c500c600c503e100c509a000c51e5000cfff1000c96f3000c50c8000c506d000c501e400c500aa00c5005e1063001820000000000000000000000000000000000000000"  ; K
    "00000000000000000000000000000000000000000390000005d0000005d0000005d0000005d0000005d0000005d0000005d0000005d0000005d0000005d0000005d0000005feeee4028888820000000000000000000000000000000000000000"  ; L
    "00000000000000000000000000000000000000000a8008a00ee00de00ec23be00f9678e00f59b5e00f2cd3e00f1db3e00f1543e00f1003e00f1003e00f1003e00f1003e00f1003e0080002700000000000000000000000000000000000000000"  ; M
    "0000000000000000000000000000000000000000088004700cf106b00ce506b00cb906b00c7d06b00c4e26b00c4a66b00c46a6b00c42e6b00c40d9b00c409cb00c405fb00c401fb0062007500000000000000000000000000000000000000000"  ; N
    "0000000000000000000000000000000000000000007cc50005faaf300a900a800c5007b00c4007b00c4007b00c4007b00c4007b00c4007b00c4007b00c5007a009b00c7004fdde20004993000000000000000000000000000000000000000000"  ; O
    "000000000000000000000000000000000000000008aaa6000ccbcf800c5007e10c5001f30c5001f40c5004f20ca77db00cfffb100c5000000c5000000c5000000c5000000c500000063000000000000000000000000000000000000000000000"  ; P
    "0000000000000000000000000000000000000000007cc60006faaf400b800aa00d4006c00e3005d00e3005d00e3005d00e3005d00e3005d00e3005d00d4006c00aa00b9004fddf200049d90000005e0000000e50000007900000000000000000"  ; Q
    "000000000000000000000000000000000000000008aaa5000bcbcf500b5009c00b5004f00b5004f00b5007d00bb9af600bdcf8000b50b8000b506c000b501f200b500b700b5007c0063002810000000000000000000000000000000000000000"  ; R
    "0000000000000000000000000000000000000000007cb50005faaf300a900b800c5005600b70000007e6100001bfe80000039f60000008c0010004e00f2004e00c900ab006fddf40005994000000000000000000000000000000000000000000"  ; S
    "00000000000000000000000000000000000000002aaaaaa23bbedbb2000a9000000a9000000a9000000a9000000a9000000a9000000a9000000a9000000a9000000a9000000a9000000540000000000000000000000000000000000000000000"  ; T
    "0000000000000000000000000000000000000000083005700c5007b00c5007b00c5007b00c5007b00c5007b00c5007b00c5007b00c5007b00c5007b00c6008a009b00c7004fddf20004994000000000000000000000000000000000000000000"  ; U
    "0000000000000000000000000000000000000000290001a21f1003f00e3005c00b60089008900a6006c00d4003f01f1001f33d0000d56a0000a88800007bb500004de300001ff000000760000000000000000000000000000000000000000000"  ; V
    "000000000000000000000000000000000000000074077046970cc088880cc097790dd0a65a1bc1b44b3aa2d32c4893e11d6785f00e7667e00e9459c00cb34bb00be12d900af01f80057007400000000000000000000000000000000000000000"  ; W
    "00000000000000000000000000000000000000001a1002a10c7008b007c00d5002f44d0000aaa800004ee300000dc000001ee100006ce50000c78b0004e12f200a900b801e3006e0270001820000000000000000000000000000000000000000"  ; X
    "0000000000000000000000000000000000000000480000931f1003e10b6008a007c00d4002f23e0000c78a00006dd500001fe000000ba000000a9000000a9000000a9000000a9000000540000000000000000000000000000000000000000000"  ; Y
    "000000000000000000000000000000000000000008aaaa6009bbbda000000c6000004e000000b8000002f2000009b000001f4000007d000000d6000005e100000b8000000deeeeb0068888600000000000000000000000000000000000000000"  ; Z
    "00000000000000000000000000388700005ffe00005e0000005e0000005e0000005e0000005e0000005e0000005e0000005e0000005e0000005e0000005e0000005e0000005e0000005e0000005fed0000399800000000000000000000000000"  ; [
    "000000000000000000000000072000000b70000007b0000003f1000000e5000000a90000006e0000002f3000000c70000008c0000004f1000000e4000000a80000006c0000002f1000000d500000099000000480000000000000000000000000"  ; backslash
    "0000000000000000000000000188820001fff4000000e4000000e4000000e4000000e4000000e4000000e4000000e4000000e4000000e4000000e4000000e4000000e4000000e4000000e40001eef40001999200000000000000000000000000"  ; ]
    "000000000000000000000000000000000000000000088000001ee100006bb40000b5690001e11d0006a00b300a500790030001200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"  ; ^
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000022222203ffffff216666661000000000000000000000000"  ; _
    "0000000000000000000000000000000000870000003e3000000790000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"  ; `
    "00000000000000000000000000000000000000000000000000000000000000000059940005fcdf300a900b80011008a000799ca008fccda00e5007a01f1008a00f501ca00afceba0018a64500000000000000000000000000000000000000000"  ; a
    "0000000000000000000000000000000000000000084000000c5000000c5000000c57a5000cbddf300cb00b900c6007b00c5006b00c5006b00c5006b00c6007b00cb00b900cbddf300637a5000000000000000000000000000000000000000000"  ; b
    "00000000000000000000000000000000000000000000000000000000000000000049940003fdcf4009b00aa00c5004900c4000000c4000000c4000000c50049009b00aa003fdcf40004994000000000000000000000000000000000000000000"  ; c
    "000000000000000000000000000000000000000000000570000007a0000007a0006a67a005fcdba00aa00ca00c5008a00c4007a00c4007a00c4007a00c5008a00aa00ca005fcdca0006a64500000000000000000000000000000000000000000"  ; d
    "00000000000000000000000000000000000000000000000000000000000000000049930004fdde200aa00b800c4006b00d8669c00dffffc00d3000000c4001100aa00a9004fddf30004994000000000000000000000000000000000000000000"  ; e
    "000000000000000000000000000000000000000000039aa0000edbb0002f1000003f1000125f32204ffffff0157f5550003f1000003f1000003f1000003f1000003f1000003f1000001800000000000000000000000000000000000000000000"  ; f
    "0000000000000000000000000000000000000000000000000000000000000000006a745005fddca00aa00ca00c5008a00c4007a00c4007a00c5008a00aa00ca005fddca0007c88a0000008a000000b8000abcf3000bcb5000000000000000000"  ; g
    "0000000000000000000000000000000000000000084000000c5000000c5000000c57a5000cbddf300cb00c800c6008a00c5007b00c5007b00c5007b00c5007b00c5007b00c5007b0063003500000000000000000000000000000000000000000"  ; h
    "0000000000000000000000000000000000047000000bf20000047000000000000588700009eee0000005e0000005e0000005e0000005e0000005e0000005e0000005e0000ceefee5068888820000000000000000000000000000000000000000"  ; i
    "00000000000000000000000000000000000056000000dd000000560000000000068885000ceeeb0000006b0000006b0000006b0000006b0000006b0000006b0000006b0000006b0000007a000001c80009bde2000acb30000000000000000000"  ; j
    "0000000000000000000000000000000000000000074000000b6000000b6000000b6002710b6009b00b601e400b608b000ba6f4000bfff1000b82e7000b606d000b600d600b6008d0053001820000000000000000000000000000000000000000"  ; k
    "00000000000000000000000000000000000000006aaa10007bcf2000002f2000002f2000002f2000002f2000002f2000002f2000002f2000002f2000002f2000001f5000000afee4000168820000000000000000000000000000000000000000"  ; l
    "0000000000000000000000000000000000000000000000000000000000000000167829403eaebbd03e0981f13d0870f23d0870f23d0870f23d0870f23d0870f23d0870f23d0870f2160440810000000000000000000000000000000000000000"  ; m
    "00000000000000000000000000000000000000000000000000000000000000000637a5000cbddf300cb00c800c6008a00c5007b00c5007b00c5007b00c5007b00c5007b00c5007b0063003500000000000000000000000000000000000000000"  ; n
    "00000000000000000000000000000000000000000000000000000000000000000049930004fdde200aa00b800c5007b00d4006c00d4006c00d4006c00c5007b00aa00b8004fdde20004993000000000000000000000000000000000000000000"  ; o
    "00000000000000000000000000000000000000000000000000000000000000000637a5000cbddf300cb00b900c6007b00c5006b00c5006b00c5006b00c6007b00cb00b900cbddf300c57a5000c5000000c500000094000000000000000000000"  ; p
    "0000000000000000000000000000000000000000000000000000000000000000006a645005fcdca00aa00ca00c5008a00c4007a00c4007a00c4007a00c5008a00aa00ca005fcdba0006a67a0000007a0000007a0000006800000000000000000"  ; q
    "00000000000000000000000000000000000000000000000000000000000000000455a70008becf7008e108c008a004e0089002b00890000008900000089000000890000008900000045000000000000000000000000000000000000000000000"  ; r
    "0000000000000000000000000000000000000000000000000000000000000000006aa50007fccf400b800a900b60000008e9620002bffe3000003c90031006b00c7008b008fccf60007aa6000000000000000000000000000000000000000000"  ; s
    "000000000000000000000000000000000000000000250000005e0000005e000038ae88605eefeec0005e0000005e0000005e0000005e0000005e0000005e0000004f1000001efeb0000278600000000000000000000000000000000000000000"  ; t
    "0000000000000000000000000000000000000000000000000000000000000000062003500c5007b00c5007b00c5007b00c5007b00c5007b00c5007b00b6008a009b00c7003fdde10004993000000000000000000000000000000000000000000"  ; u
    "0000000000000000000000000000000000000000000000000000000000000000170001810f3005e00c6008a008a00b6005e00e2002f23e0000d66b000099a700005dd400002ff100000760000000000000000000000000000000000000000000"  ; v
    "000000000000000000000000000000000000000000000000000000000000000043055044780cb096590cc0b43b1cd0d21c3ab2e00d5894d00d7687b00ba46b900ad24d7008f02f50037007200000000000000000000000000000000000000000"  ; w
    "0000000000000000000000000000000000000000000000000000000000000000072003700aa00b9004f22f2000b99900003ef300000ed000005ee30000d88b0005e11f300c8009b0181002710000000000000000000000000000000000000000"  ; x
    "0000000000000000000000000000000000000000000000000000000000000000170001810e3005e00b7008a007c00c5002f11f1000e54c00009a8900005ec500001ef100000bc000000c8000001f3000005e0000007800000000000000000000"  ; y
    "0000000000000000000000000000000000000000000000000000000000000000058888400aeeef8000001e500000ab000004f300000c9000006e100001e6000009b000000ceeeea0068888500000000000000000000000000000000000000000"  ; z
    "000000000000000000000000000017500000dfa00005f2000005d0000005e0000004f0000003f1000004e0000aac60000bbe60000004e0000002f1000003f0000004e0000005d0000005e2000001df9000002860000000000000000000000000"  ; {
    "00000000000000000000000000054000000a9000000a9000000a9000000a9000000a9000000a9000000a9000000a9000000a9000000a9000000a9000000a9000000a9000000a9000000a9000000a900000065000000000000000000000000000"  ; |
    "000000000000000000000000066100000bfc0000003f4000000e5000000f3000002f1000004f0000003f10000009ca90000beba0003f1000004e0000002f1000001f3000000e4000002f40000afd000007710000000000000000000000000000"  ; }
    "0000000000000000000000000000000000000000000000000000000000000000000000000000000004b702a00dbe53f00f07ebd01d00be5000000000000000000000000000000000000000000000000000000000000000000000000000000000"  ; ~
   )
  "Ink coverage of printable ASCII, taken from JetBrainsMono.
One hex digit per cell of an 8x24 grid per character, row-major, from
space to tilde.  At the size a minimap draws, the font engine is itself
doing little more than area-averaging outlines, so this does the same
once and offline at high resolution against a real font; the package
averages it down to whatever cell it is drawing into.  Guessing at these
numbers by hand, which is what came before, is what made text read as a
bar rather than as text.  Regenerate with tools/gen-glyph-table.py.")

(defconst canvas-minimap--shipped-glyph-font "JetBrains Mono"
  "Font `canvas-minimap--glyph-coverage' was taken from.")

(defconst canvas-minimap--directory
  (file-name-directory (or load-file-name
                           (locate-library "canvas-minimap")
                           default-directory))
  "Where this package lives, so its tools can be found.")

(defvar canvas-minimap--states)         ; the registry, defined below
(defvar canvas-minimap--glyph-cache)    ; defined with the glyph tables

(defvar canvas-minimap--glyph-tables (make-hash-table :test 'equal)
  "Font family -> coverage string, for fonts other than the shipped one.")

(defvar canvas-minimap--glyph-pending nil
  "Font family a generation is running for, if any.")

(defun canvas-minimap--font-family ()
  "Family of the frame's default font, as a string."
  (or (ignore-errors
        (let ((f (face-attribute 'default :font)))
          (and (fontp f) (format "%s" (font-get f :family)))))
      (let ((fam (face-attribute 'default :family nil t)))
        (and (stringp fam) fam))
      canvas-minimap--shipped-glyph-font))

(defun canvas-minimap--font-name-key (family)
  "Compare font names without caring about spacing or case.
Emacs reports whatever the user configured -- \"JetBrainsMono\" -- while
fontconfig calls the same face \"JetBrains Mono\"."
  (downcase (replace-regexp-in-string "[ _-]" "" (or family ""))))

(defun canvas-minimap--glyph-file (family)
  "Path the cached table for FAMILY lives at."
  (expand-file-name (concat (replace-regexp-in-string "[^A-Za-z0-9._-]" "_" family)
                            ".txt")
                    canvas-minimap-glyph-directory))

(defun canvas-minimap--coverage-length ()
  "Hex digits a complete coverage table holds."
  (* 95 canvas-minimap--glyph-width canvas-minimap--glyph-height))

(defun canvas-minimap--font-file (family)
  "Path to a TrueType file for FAMILY, via fc-match, or nil."
  (when (executable-find "fc-match")
    ;; A pooled buffer keeps the default-directory its last user left;
    ;; run fc-match from the caller's, which is at least as alive.
    (let* ((dir default-directory)
           (out (string-trim
                 (with-work-buffer
                   (let ((default-directory dir))
                     (ignore-errors
                       (call-process "fc-match" nil t nil "-f" "%{file}" family)))
                   (buffer-string)))))
      (and (not (string-empty-p out)) (file-readable-p out) out))))

(defun canvas-minimap--active-coverage (family)
  "Coverage table to draw FAMILY with.
One is generated in the background if there is none, and the shipped
table is used until it arrives."
  (or (and (equal (canvas-minimap--font-name-key family)
                  (canvas-minimap--font-name-key canvas-minimap--shipped-glyph-font))
           canvas-minimap--glyph-coverage)
      (gethash family canvas-minimap--glyph-tables)
      (let ((file (canvas-minimap--glyph-file family)))
        (when (file-readable-p file)
          (let ((text (string-trim
                       (with-work-buffer
                         (insert-file-contents file)
                         (buffer-string)))))
            (when (= (length text) (canvas-minimap--coverage-length))
              (puthash family text canvas-minimap--glyph-tables)))))
      (progn
        (when canvas-minimap-glyph-auto-generate
          (canvas-minimap--generate-glyph-table family))
        canvas-minimap--glyph-coverage)))

(defun canvas-minimap--generate-glyph-table (family)
  "Rasterize a glyph table for FAMILY in the background."
  (let ((script (expand-file-name "tools/gen-glyph-table.py"
                                  canvas-minimap--directory))
        (font (canvas-minimap--font-file family))
        (out (canvas-minimap--glyph-file family)))
    (when (and font
               (not (equal family canvas-minimap--glyph-pending))
               (file-exists-p script)
               (executable-find "python3"))
      (setq canvas-minimap--glyph-pending family)
      (make-directory (file-name-directory out) t)
      (let ((stdout (generate-new-buffer " *canvas-minimap-glyphs*"))
            (stderr (generate-new-buffer " *canvas-minimap-glyphs-err*")))
        (condition-case err
            (make-process
             :name "canvas-minimap-glyphs"
             :buffer stdout
             :stderr stderr
             :noquery t
             :command (list "python3" script font)
             :sentinel
             (lambda (proc _event)
               (when (memq (process-status proc) '(exit signal))
                 (let ((text (with-current-buffer stdout
                               (string-trim (buffer-string)))))
                   (setq canvas-minimap--glyph-pending nil)
                   (when (buffer-live-p stdout) (kill-buffer stdout))
                   (when (buffer-live-p stderr) (kill-buffer stderr))
                   (if (/= (length text) (canvas-minimap--coverage-length))
                       (message "canvas-minimap: could not rasterize %s" family)
                     (write-region text nil out nil 'silent)
                     (puthash family text canvas-minimap--glyph-tables)
                     (clrhash canvas-minimap--glyph-cache)
                     ;; Drop what was drawn so the next refresh rebuilds.
                     (clrhash canvas-minimap--states)
                     (canvas-minimap--schedule)
                     (message "canvas-minimap: glyph table ready for %s" family))))))
          (error
           (setq canvas-minimap--glyph-pending nil)
           (when (buffer-live-p stdout) (kill-buffer stdout))
           (when (buffer-live-p stderr) (kill-buffer stderr))
           (message "canvas-minimap: %s" (error-message-string err))))))))

(defun canvas-minimap-regenerate-glyph-table ()
  "Rasterize a glyph table for the frame's font, replacing any cached one."
  (interactive)
  (let ((family (canvas-minimap--font-family)))
    (remhash family canvas-minimap--glyph-tables)
    (setq canvas-minimap--glyph-pending nil)
    (canvas-minimap--generate-glyph-table family)
    (message "canvas-minimap: rasterizing %s..." family)))

(defconst canvas-minimap--glyph-fallback
  ;; Anything with no coverage of its own -- non-ASCII, control characters --
  ;; gets a body that fills the x-height band without pretending to a shape.
  (let* ((w canvas-minimap--glyph-width)
         (h canvas-minimap--glyph-height)
         (v (make-vector (* w h) 0)))
    (dotimes (r h)
      (dotimes (x w)
        (aset v (+ (* r w) x)
              (if (and (> r (/ h 4)) (< r (- h (/ h 5)))
                       (> x 0) (< x (1- w)))
                  10 0))))
    v))

(defun canvas-minimap--glyph-cell (c coverage)
  "Coverage grid for character C in COVERAGE, as a vector of 0-15 levels."
  (let ((i (- c canvas-minimap--glyph-first))
        (n (* canvas-minimap--glyph-width canvas-minimap--glyph-height)))
    (if (and (>= i 0) (< (* (1+ i) n) (1+ (length coverage))))
        (let ((v (make-vector n 0))
              (off (* i n)))
          (dotimes (k n)
            (aset v k (string-to-number
                       (substring coverage (+ off k) (+ off k 1))
                       16)))
          v)
      canvas-minimap--glyph-fallback)))

(defun canvas-minimap--downsample (cell out-w out-h)
  "Area-average CELL's coverage grid down to OUT-W by OUT-H levels.
Fractional overlaps are weighted, so a cell two pixels across gets the
same answer the font engine would arrive at by rasterizing that small."
  (let* ((gw canvas-minimap--glyph-width)
         (gh canvas-minimap--glyph-height)
         (out (make-vector (* out-w out-h) 0))
         (sy (/ (float gh) out-h))
         (sx (/ (float gw) out-w)))
    (dotimes (r out-h)
      (dotimes (x out-w)
        (let* ((y0 (* r sy)) (y1 (* (1+ r) sy))
               (x0 (* x sx)) (x1 (* (1+ x) sx))
               (acc 0.0) (wsum 0.0)
               (sr (floor y0)))
          (while (< sr (min gh (ceiling y1)))
            (let ((wy (- (min y1 (float (1+ sr))) (max y0 (float sr))))
                  (sc (floor x0)))
              (when (> wy 0)
                (while (< sc (min gw (ceiling x1)))
                  (let ((wx (- (min x1 (float (1+ sc))) (max x0 (float sc)))))
                    (when (> wx 0)
                      (setq acc (+ acc (* wy wx (aref cell (+ (* sr gw) sc))))
                            wsum (+ wsum (* wy wx)))))
                  (setq sc (1+ sc)))))
            (setq sr (1+ sr)))
          (aset out (+ (* r out-w) x)
                (if (> wsum 0) (min 15 (round (/ acc wsum))) 0)))))
    out))

(defvar canvas-minimap--glyph-cache (make-hash-table :test 'equal)
  "(INK-ROWS CW FONT DETAIL) -> glyph table.
Shared: a table depends on the geometry and the font, not on which
window is being drawn, and there is no sense in every minimap on a
frame rasterizing its own copy.")

(defun canvas-minimap--glyph-table (ink-rows cw family)
  "Glyph table for INK-ROWS by CW cells of FAMILY, built once."
  (let ((key (list ink-rows cw family canvas-minimap-glyph-detail)))
    (or (gethash key canvas-minimap--glyph-cache)
        (puthash key
                 (canvas-minimap--build-glyph-rows
                  ink-rows cw (canvas-minimap--active-coverage family))
                 canvas-minimap--glyph-cache))))

(defun canvas-minimap--build-glyph-rows (ink-rows cw coverage)
  "Per-character ink levels for INK-ROWS rows of CW columns each.
Averaging the real coverage down once per geometry, rather than per
drawn glyph, keeps the inner rasterizing loop to two array lookups."
  (let ((table (make-vector 129 nil)))
    (dotimes (c 129)
      (aset table c
            (if canvas-minimap-glyph-detail
                (canvas-minimap--downsample
                 (canvas-minimap--glyph-cell c coverage) cw ink-rows)
              ;; Flat look: anything carrying ink fills its cell.
              (let* ((cell (canvas-minimap--glyph-cell c coverage))
                     (ink (let ((n 0))
                            (dotimes (k (length cell))
                              (setq n (+ n (aref cell k))))
                            n)))
                (make-vector (* cw ink-rows) (if (> ink 0) 15 0))))))
    ;; A glyph covers well under half its cell, so raw coverage never comes
    ;; near the top of the blend table and the whole picture reads washed
    ;; out.  Stretch the densest glyph to full ink and everything else with
    ;; it, which keeps the ratios and uses the range the table has.
    (when canvas-minimap-glyph-detail
      (let ((peak 0))
        (dotimes (c 129)
          (let ((v (aref table c)))
            (dotimes (k (length v))
              (when (> (aref v k) peak) (setq peak (aref v k))))))
        (when (and (> peak 0) (< peak 15))
          (let ((gain (/ 15.0 peak)))
            (dotimes (c 129)
              (let ((v (aref table c)))
                (dotimes (k (length v))
                  (aset v k (min 15 (round (* gain (aref v k))))))))))))
    table))

(defun canvas-minimap--device-scale ()
  "Canvas pixels per window pixel, as a positive integer."
  (max 1 (round (if (eq canvas-minimap-device-scale 'auto)
                    (or (ignore-errors (frame-scale-factor)) 1)
                  canvas-minimap-device-scale))))

(defun canvas-minimap--ink-rows (&optional scale)
  "Number of pixel rows a line gets to draw ink in, at SCALE."
  (let* ((sc (or scale (canvas-minimap--device-scale)))
         (base (max 1 canvas-minimap-line-height)))
    (max 1 (* sc (- base (min canvas-minimap-line-gap (1- base)))))))

;;;; The fringe

;; Rather than knowing about diff-hl, flycheck, flymake, dape and the
;; rest, read what is actually in the fringe.  Every one of them marks a
;; line the same way: an overlay whose `before-string' carries a display
;; spec naming a bitmap and a face.  Mirroring that gets all of them,
;; and anything else that shows up there later, for free.

(defun canvas-minimap--fringe-face (spec)
  "Face named by a fringe indicator in display SPEC, or nil.
Display specs nest -- diff-hl's reads ((left-fringe BITMAP FACE)) --
so a fringe indicator can be SPEC itself or one element of a list."
  (cond
   ((not (consp spec)) nil)
   ((memq (car spec) '(left-fringe right-fringe))
    (or (nth 2 spec) 'fringe))
   (t (let ((l spec) res)
        (while (and (consp l) (not res))
          (setq res (canvas-minimap--fringe-face (car l))
                l (cdr l)))
        res))))

(defun canvas-minimap--fringe-pix (st face)
  "ARGB32 to draw a fringe indicator carrying FACE with, cached in ST.
A fringe bitmap is drawn in its face's foreground, so that is what the
strip should show."
  (let ((cache (canvas-minimap--state-gutter-colors st)))
    (or (gethash face cache)
        (puthash face
                 (let ((rgb (or (canvas-minimap--rgb
                                 (canvas-minimap--face-attr face :foreground))
                                (canvas-minimap--rgb
                                 (canvas-minimap--face-attr face :background))
                                (canvas-minimap--rgb
                                 (face-attribute 'fringe :foreground nil t))
                                (canvas-minimap--state-fg st))))
                   (canvas-minimap--argb (nth 0 rgb) (nth 1 rgb) (nth 2 rgb)))
                 cache))))

(defun canvas-minimap--overlay-fringe-face (ov win)
  "Face of the fringe indicator OV puts on its line, or nil.
An overlay bound to a window other than WIN is not showing here."
  (let ((ow (overlay-get ov 'window)))
    (when (or (null ow) (eq ow win))
      (let ((res nil))
        (dolist (prop '(before-string after-string))
          (unless res
            (let ((str (overlay-get ov prop)))
              (when (stringp str)
                (setq res (canvas-minimap--fringe-face
                           (get-text-property 0 'display str)))))))
        res))))

;;;; State

(cl-defstruct (canvas-minimap--state
               (:constructor canvas-minimap--state-create))
  image                ; the canvas image spec, mutated in place
  data                 ; the canvas pixel buffer, mutated in place
  width height         ; canvas size, in pixels
  rows                 ; number of line slots the canvas holds
  slot-pixels          ; pixels occupied by one slot
  buffer window        ; source buffer and window the render belongs to
  start                ; buffer line drawn in slot 0 (1-based)
  cookies              ; per slot: the buffer line drawn there, nil for a
                       ; slot past the end of the buffer, `unknown' when
                       ; nothing has been drawn there yet
  slot-of              ; buffer line -> slot, as last drawn
  slot-pos             ; per slot: where its line starts in the buffer, nil
                       ; for a slot past the end
  parts                ; per slot: which slot of its line this is, counting
                       ; from 0; -1 when nothing has been drawn there
  deco                 ; per slot: which decoration is painted on it
  save-buf             ; per slot: the text pixels decoration covers
  text-slot-pixels     ; text-column pixels in one slot
  bg fg                ; default background/foreground, as rgb lists
  bgpix                ; background as ARGB32
  spec-memo            ; face spec -> [BGPIX LUT EXTEND], one pass only
  overlays             ; overlay -> [START END FACE] as last drawn
  slice-beg slice-end  ; markers bounding the drawn slice
  gutter-colors        ; fringe face -> ARGB32
  gutter               ; per slot: the fringe colour painted there, nil for
                       ; none, `unknown' when the pixels are not accounted for
  top                  ; pixel row slot 0 starts on, below the layout strip
  layout               ; what the strip was last drawn from
  text-x0 text-x1      ; pixel columns the text may use
  gut-x0 gut-x1        ; pixel columns the fringe strip uses
  char-w               ; the default font's advance, in window pixels
  scale                ; canvas pixels per window pixel
  lh cw gut-w ph       ; line height, column width, strip width, marker
  ink-rows             ; pixel rows a line draws ink in
  glyph-rows           ; character -> per-row, per-column ink levels
  glyph-cw             ; column width that table was built for
  glyph-font           ; font family that table was rasterized from
  detail               ; `canvas-minimap-glyph-detail' this table was built for
  tint-r tint-g tint-b ; 256-entry viewport tint tables, per channel
  match-r match-g match-b ; the same, for a matched line
  point-pix            ; point marker colour, as ARGB32
  vp-line-pix          ; viewport outline colour, as ARGB32
  deco-sig)            ; the decoration options the two were built from

(defvar canvas-minimap--states (make-hash-table :test 'eq :weakness 'key)
  "Minimap window -> its `canvas-minimap--state'.
Keyed weakly: a deleted window takes its state with it.")

;; Loading the file a second time -- which is what happens while working
;; on it -- leaves the states from the first behind, and a state built
;; before a field was added to the struct is read with the new field
;; offsets: a hash table turns up where a marker belongs.  They are
;; drawings, not settings, so throwing them away costs one redraw.
(clrhash canvas-minimap--states)



(defvar canvas-minimap--timer nil)

(defvar canvas-minimap--rendering nil
  "Bound while rasterizing, so fontification does not look like an edit.")

(defvar-local canvas-minimap--dirty nil
  "Buffer lines needing a redraw: a cons (MIN . MAX), or nil.
MAX is `most-positive-fixnum' when a change shifted every line below it.")

(defvar-local canvas-minimap--pending-lines nil
  "Line count of the region `before-change-functions' last saw.")

(defvar canvas-minimap-mode)            ; defined by the minor mode below
(defvar canvas-minimap-image-map)       ; defined with the mouse commands

(defvar canvas-minimap--luts (make-hash-table :test 'equal)
  "(BGPIX . FGPIX) -> 16-entry ink table, shared across minimaps.")

(defvar canvas-minimap--advances (make-hash-table :test 'equal)
  "Font key -> vector of per-character pixel advances, filled lazily.")

(defun canvas-minimap--font-key (spec)
  "Key identifying SPEC's font, or nil if it draws in the default one.
Only family and height move a glyph's advance; weight and slant leave a
monospace face the width it was, so faces that merely recolour text --
most of what font-lock does -- never need measuring."
  (let ((family (canvas-minimap--face-attr spec :family))
        (height (canvas-minimap--face-attr spec :height)))
    (and (or family height) (list family height))))

(defun canvas-minimap--advance (spec key ch base)
  "Pixel advance of CH drawn with face SPEC, whose font is KEY.
BASE is the default font's advance, which is the answer whenever the
face does not change the font."
  (if (null key)
      (* base (max 1 (char-width ch)))
    (let ((tab (or (gethash key canvas-minimap--advances)
                   (puthash key (make-vector 128 nil)
                            canvas-minimap--advances))))
      (if (< ch 128)
          (or (aref tab ch)
              (aset tab ch
                    (max 1 (string-pixel-width
                            (propertize (char-to-string ch) 'face spec)))))
        (max 1 (string-pixel-width
                (propertize (char-to-string ch) 'face spec)))))))

(defun canvas-minimap--style-for (st spec)
  "Drawing style for face SPEC, as [BGPIX LUT EXTEND].
BGPIX is the face background, LUT its ink table over that background,
and EXTEND whether the face reaches past the end of the line.

Colours are resolved afresh every pass and only the expensive part --
building the ink table -- is cached, keyed on the resolved colours
rather than on the face.  A face spec is not a stable name for a
colour: `pulse-highlight-face' keeps its name while `pulse-tick'
repaints its background out from under it, and caching by name would
freeze a pulse at whichever step of the fade was seen first.  Resolving
is cheap; the per-pass memo means each distinct face is looked at once."
  (let ((memo (canvas-minimap--state-spec-memo st)))
    (or (gethash spec memo)
        (puthash spec
                 (let* ((bg (or (canvas-minimap--rgb
                                 (canvas-minimap--face-attr spec :background))
                                (canvas-minimap--state-bg st)))
                        (fg (or (canvas-minimap--rgb
                                 (canvas-minimap--face-attr spec :foreground))
                                (canvas-minimap--state-fg st)))
                        (bgpix (canvas-minimap--argb (nth 0 bg) (nth 1 bg) (nth 2 bg)))
                        (key (cons bgpix
                                   (canvas-minimap--argb (nth 0 fg) (nth 1 fg)
                                                         (nth 2 fg))))
                        (luts canvas-minimap--luts))
                   (vector bgpix
                           (or (gethash key luts)
                               (puthash key (canvas-minimap--make-lut bg fg) luts))
                           (and (canvas-minimap--face-attr spec :extend) t)
                           (canvas-minimap--font-key spec)
                           spec))
                 memo))))

(defun canvas-minimap--blend (from to f)
  "Rgb list F of the way from rgb list FROM to rgb list TO."
  (list (round (+ (* (- 1.0 f) (nth 0 from)) (* f (nth 0 to))))
        (round (+ (* (- 1.0 f) (nth 1 from)) (* f (nth 1 to))))
        (round (+ (* (- 1.0 f) (nth 2 from)) (* f (nth 2 to))))))

(defun canvas-minimap--mix (from to f)
  "ARGB32 of the colour F of the way from rgb list FROM to rgb list TO."
  (apply #'canvas-minimap--argb (canvas-minimap--blend from to f)))

(defun canvas-minimap--blend-table (target alpha)
  "Table taking one channel of a pixel ALPHA of the way to TARGET."
  (let ((v (make-vector 256 0))
        (ia (- 1.0 alpha)))
    (dotimes (c 256)
      (aset v c (round (+ (* ia c) (* alpha target)))))
    v))

(defun canvas-minimap--deco-signature ()
  "The options the decoration\'s colours are made from.
Kept with the state so a change to any of them is noticed: the tables
are built once and the tint would otherwise stay as it was until
something else rebuilt the map."
  (list canvas-minimap-viewport-color canvas-minimap-viewport-alpha
        canvas-minimap-viewport-style canvas-minimap-viewport-outline-color
        canvas-minimap-match-color canvas-minimap-match-alpha
        canvas-minimap-point-color canvas-minimap-show-point
        canvas-minimap-point-height))

(defun canvas-minimap--tint-tables (st)
  "Build ST's viewport and match tint tables from the current colours."
  (let ((vp (or (canvas-minimap--rgb
                 (or canvas-minimap-viewport-color
                     (face-background 'region nil t)))
                (canvas-minimap--state-fg st)))
        (va (min 1.0 (max 0.0 canvas-minimap-viewport-alpha)))
        (mt (or (canvas-minimap--rgb
                 (or canvas-minimap-match-color
                     (face-background 'lazy-highlight nil t)
                     (face-background 'match nil t)))
                (canvas-minimap--state-fg st)))
        (ma (min 1.0 (max 0.0 canvas-minimap-match-alpha))))
    (setf (canvas-minimap--state-vp-line-pix st)
          (apply #'canvas-minimap--argb
                 (or (canvas-minimap--rgb canvas-minimap-viewport-outline-color)
                     (canvas-minimap--blend (canvas-minimap--state-bg st)
                                            (canvas-minimap--state-fg st) 0.42)))
          (canvas-minimap--state-deco-sig st) (canvas-minimap--deco-signature))
    (setf (canvas-minimap--state-tint-r st) (canvas-minimap--blend-table (nth 0 vp) va)
          (canvas-minimap--state-tint-g st) (canvas-minimap--blend-table (nth 1 vp) va)
          (canvas-minimap--state-tint-b st) (canvas-minimap--blend-table (nth 2 vp) va)
          (canvas-minimap--state-match-r st) (canvas-minimap--blend-table (nth 0 mt) ma)
          (canvas-minimap--state-match-g st) (canvas-minimap--blend-table (nth 1 mt) ma)
          (canvas-minimap--state-match-b st) (canvas-minimap--blend-table (nth 2 mt) ma))))

(defun canvas-minimap--make-state (width height frame)
  "Return a fresh state with a WIDTH x HEIGHT canvas, for a window of FRAME."
  (let* ((sc (canvas-minimap--device-scale))
         (family (canvas-minimap--font-family))
         (width (* sc width))
         (height (* sc height))
         (lh (* sc (max 1 canvas-minimap-line-height)))
         ;; The strip never takes so much that there is no map left.
         (top (min (canvas-minimap--layout-height width sc frame)
                   (max 0 (- height (* 8 lh)))))
         (rows (max 1 (/ (- height top) lh)))
         (size (* width height))
         (bg (or (canvas-minimap--rgb (face-background 'default nil t))
                 '(0 0 0)))
         (fg (or (canvas-minimap--rgb (face-foreground 'default nil t))
                 '(255 255 255)))
         (bgpix (canvas-minimap--argb (nth 0 bg) (nth 1 bg) (nth 2 bg)))
         (data (make-vector size bgpix))
         (ink-rows (canvas-minimap--ink-rows sc))
         (cw (* sc (max 1 canvas-minimap-column-width)))
         (gut (max 0 (min (* sc (max 0 canvas-minimap-gutter-width))
                          (/ width 2))))
         (tsp (* (- width gut) lh))
         (st (canvas-minimap--state-create
              :data data
              :char-w (max 1 (frame-char-width))
              :scale sc :lh lh :cw cw :gut-w gut
              :ph (* sc (max 1 canvas-minimap-point-height))
              :ink-rows ink-rows
              :glyph-rows (canvas-minimap--glyph-table ink-rows cw family)
              :glyph-cw cw :glyph-font family
              :detail canvas-minimap-glyph-detail
              :deco (make-vector rows 0)
              :save-buf (make-vector (* rows tsp) 0)
              :text-slot-pixels tsp
              :top top
              :width width :height height :rows rows
              :slot-pixels (* width lh)
              :start 1
              :cookies (make-vector rows 'unknown)
              :slot-of (make-hash-table :test 'eql)
              :slot-pos (make-vector rows nil)
              :parts (make-vector rows -1)
              :gutter (make-vector rows nil)
              :gutter-colors (make-hash-table :test 'equal)
              :text-x0 (if (eq canvas-minimap-gutter-side 'left) gut 0)
              :text-x1 (if (eq canvas-minimap-gutter-side 'left) width (- width gut))
              :gut-x0 (if (eq canvas-minimap-gutter-side 'left) 0 (- width gut))
              :gut-x1 (if (eq canvas-minimap-gutter-side 'left) gut width)
              :bg bg :fg fg :bgpix bgpix
              :spec-memo (make-hash-table :test 'equal)
              :overlays (make-hash-table :test 'eq)
              :slice-beg (make-marker)
              :slice-end (make-marker)
              :point-pix
              (let ((c (or (canvas-minimap--rgb
                            (or canvas-minimap-point-color
                                (frame-parameter nil 'cursor-color)))
                           fg)))
                (canvas-minimap--argb (nth 0 c) (nth 1 c) (nth 2 c))))))
    (setf (canvas-minimap--state-image st)
          (create-image data 'canvas t
                        ;; The manual has :id among the mandatory
                        ;; properties, though `create-image' does not ask
                        ;; for one.  A canvas per state, named for it.
                        :id (gensym "canvas-minimap-")
                        :data-width width :data-height height
                        :scale (if (= sc 1) 1 (/ 1.0 sc))))
    (canvas-minimap--tint-tables st)
    st))

(defun canvas-minimap--invalidate (&optional st)
  "Forget everything ST has drawn, so the next update repaints it all."
  (when-let* ((st st))
    ;; `unknown', not nil: nil is a slot that ran off the end of the
    ;; buffer and was blanked on purpose, and a blank slot must not be
    ;; mistaken for one already holding the right nothing.
    (fillarray (canvas-minimap--state-cookies st) 'unknown)
    (fillarray (canvas-minimap--state-parts st) -1)
    (clrhash (canvas-minimap--state-slot-of st))
    ;; `unknown', not nil: nil means "no mark is painted here", which would
    ;; let the strip keep pixels nobody put there.
    (fillarray (canvas-minimap--state-gutter st) 'unknown)
    (clrhash (canvas-minimap--state-overlays st))
    (setf (canvas-minimap--state-layout st) nil)
    (fillarray (canvas-minimap--state-deco st) 0)))

;;;; Rasterizing

(defsubst canvas-minimap--slot-y (st slot)
  "Canvas pixel row SLOT begins on."
  (+ (canvas-minimap--state-top st) (* slot (canvas-minimap--state-lh st))))

(defsubst canvas-minimap--fill-cell (data w y0 rows x0 x1 pix)
  "Fill ROWS rows from Y0, columns X0 to X1, of DATA with PIX.
W is the canvas width in pixels."
  (let ((dy 0))
    (while (< dy rows)
      (let ((base (* (+ y0 dy) w))
            (x x0))
        (while (< x x1)
          (aset data (+ base x) pix)
          (setq x (1+ x))))
      (setq dy (1+ dy)))))

(defun canvas-minimap--blank-slot (st slot)
  "Fill SLOT's text columns with the background.
The fringe strip is left alone: it is owned by the gutter pass, so
re-rasterizing a line never has to repaint its indicator."
  (canvas-minimap--fill-cell (canvas-minimap--state-data st)
                             (canvas-minimap--state-width st)
                             (canvas-minimap--slot-y st slot)
                             (canvas-minimap--state-lh st)
                             (canvas-minimap--state-text-x0 st)
                             (canvas-minimap--state-text-x1 st)
                             (canvas-minimap--state-bgpix st)))

(defun canvas-minimap--render-slot (st slot beg end win)
  "Rasterize the buffer text between BEG and END into ST's SLOT.
Runs in the source buffer.  WIN is the source window, which decides
which window-specific overlays -- the region, and `hl-line' when it is
not sticky -- count as visible.

Position is tracked in the buffer's own pixels rather than in columns,
so text that is not the default width lands where it actually lands: an
org heading is wider than its character count, and a `variable-pitch'
line is not on a grid at all.  For a monospace line every advance is the
default one and this reduces to the column arithmetic it replaced.

Whitespace leaves the background showing, which is what gives the
minimap its indentation profile.  A face background is painted under the
whole cell first, spaces included, so a region or a highlighted line
reads as a band; a face that extends past the end of the line carries
its background to the edge of the canvas, the way the display does."
  (canvas-minimap--blank-slot st slot)
  (let* ((data (canvas-minimap--state-data st))
         (w (canvas-minimap--state-width st))
         (lh (canvas-minimap--state-lh st))
         (ink-rows (canvas-minimap--state-ink-rows st))
         (levels (canvas-minimap--state-glyph-rows st))
         (cw (canvas-minimap--state-cw st))
         (tx0 (canvas-minimap--state-text-x0 st))
         (tx1 (canvas-minimap--state-text-x1 st))
         (y0 (canvas-minimap--slot-y st slot))
         (base (canvas-minimap--state-char-w st))
         (xs (/ (float cw) base))       ; canvas pixels per buffer pixel
         (tabpx (* (max 1 tab-width) base))
         (default-bg (canvas-minimap--state-bgpix st))
         (pos beg)
         (px 0))
    (while (and (< pos end) (< (+ tx0 (floor (* px xs))) tx1))
      ;; Text the display is not showing takes up no room on the line:
      ;; an org link is as wide as its description.  An ellipsis stands
      ;; for what is hidden on screen; three characters of it is not
      ;; worth the trouble here.
      (if (invisible-p pos)
          (setq pos (next-single-char-property-change pos 'invisible nil end))
        ;; Scan for run boundaries in the buffer -- `next-single-char-property-change'
        ;; will not take a window -- but read each run's face through WIN, so
        ;; window-specific overlays are attributed to the right window.
        (let* ((run (min (next-single-char-property-change pos 'face nil end)
                         (next-single-char-property-change pos 'invisible nil end)))
               (style (canvas-minimap--style-for st (get-char-property pos 'face win)))
               (bgpix (aref style 0))
               (lut (aref style 1))
               (fkey (aref style 3))
               (fspec (aref style 4)))
          (while (and (< pos run) (< (+ tx0 (floor (* px xs))) tx1))
            (let* ((ch (char-after pos))
                   (adv (if (eq ch ?\t)
                            (- (* (1+ (/ px tabpx)) tabpx) px)
                          (canvas-minimap--advance fspec fkey ch base)))
                   (x0 (+ tx0 (floor (* px xs))))
                   (x1 (min tx1 (max (1+ x0)
                                     (+ tx0 (floor (* (+ px adv) xs)))))))
              (unless (eql bgpix default-bg)
                (canvas-minimap--fill-cell data w y0 lh x0 x1 bgpix))
              (unless (memq ch '(?\t ?\s ?\N{NO-BREAK SPACE}))
                (let* ((cells-tab (aref levels (if (< ch 128) ch 128)))
                       (span (- x1 x0))
                       (dy 0))
                  (while (< dy ink-rows)
                    (let ((row (* (+ y0 dy) w))
                          (off (* dy cw))
                          (dx 0))
                      (while (< dx span)
                        ;; The coverage table is CW wide; a glyph drawn wider
                        ;; or narrower than that samples across it.
                        (let ((lvl (aref cells-tab
                                         (+ off (if (= span cw)
                                                    dx
                                                  (min (1- cw)
                                                       (/ (* dx cw) span)))))))
                          (unless (eq lvl 0)
                            (aset data (+ row x0 dx) (aref lut lvl))))
                        (setq dx (1+ dx))))
                    (setq dy (1+ dy)))))
              (setq px (+ px adv)))
            (setq pos (1+ pos))))))
    ;; The newline carries the face of anything that extends past the text.
    (let ((x (+ tx0 (floor (* px xs)))))
      (when (< x tx1)
        (let ((style (canvas-minimap--style-for st (get-char-property end 'face win))))
          (when (and (aref style 2) (not (eql (aref style 0) default-bg)))
            (canvas-minimap--fill-cell data w y0 lh x tx1 (aref style 0))))))))

(defun canvas-minimap--fringe-marks (st buf win rows)
  "Return a vector of ROWS fringe colours, or nil where a line has none.
Only overlays that begin on a line count: that is the line the display
puts their indicator on.  Runs after the slice is drawn, and works over
what was drawn, so a mark lands on the slot its line actually got."
  (let ((marks (make-vector rows nil))
        (base (let ((c (aref (canvas-minimap--state-cookies st) 0)))
                (and (integerp c) c)))
        (mbeg (marker-position (canvas-minimap--state-slice-beg st)))
        (mend (marker-position (canvas-minimap--state-slice-end st))))
    (when (and base mbeg mend
               (> (canvas-minimap--state-gut-x1 st)
                  (canvas-minimap--state-gut-x0 st)))
      (let ((win (and (window-live-p win) (eq (window-buffer win) buf) win)))
        (with-current-buffer buf
          (save-excursion
            (save-restriction
              (widen)
              (let* ((beg mbeg)
                     (end (max mend mbeg))
                     (best (make-vector rows -1)))
                (dolist (ov (overlays-in beg (max end beg)))
                  (let ((os (overlay-start ov)))
                    (when (and (>= os beg) (< os end))
                      (when-let* ((face (canvas-minimap--overlay-fringe-face ov win))
                                  (line (+ base
                                           (count-lines
                                            beg (save-excursion
                                                  (goto-char os)
                                                  (line-beginning-position)))))
                                  (slot (canvas-minimap--slot-of-line st line))
                                  ((< -1 slot rows))
                                  (pri (let ((p (overlay-get ov 'priority)))
                                         (if (integerp p) p 0)))
                                  ((>= pri (aref best slot))))
                        (aset marks slot (canvas-minimap--fringe-pix st face))
                        (aset best slot pri)))))))))))
    marks))

(defun canvas-minimap--render-gutter (st marks)
  "Paint the fringe strip from MARKS, repainting only what changed.
Return non-nil if any pixel was touched.
A slot recorded as `unknown' is repainted whatever MARKS says, because
its pixels came from somewhere else -- a scroll copies whole slots, the
strip included -- and nothing else would ever clear them."
  (let ((gut0 (canvas-minimap--state-gut-x0 st))
        (gut1 (canvas-minimap--state-gut-x1 st))
        (painted nil))
    (when (< gut0 gut1)
      (let ((data (canvas-minimap--state-data st))
            (w (canvas-minimap--state-width st))
            (lh (canvas-minimap--state-lh st))
            (bg (canvas-minimap--state-bgpix st))
            (cur (canvas-minimap--state-gutter st))
            (rows (canvas-minimap--state-rows st))
            (i 0))
        (while (< i rows)
          (let ((want (aref marks i)))
            (unless (eql want (aref cur i))
              (canvas-minimap--fill-cell data w (canvas-minimap--slot-y st i)
                                         lh gut0 gut1 (or want bg))
              (aset cur i want)
              (setq painted t)))
          (setq i (1+ i)))))
    painted))

(defun canvas-minimap--yield-to-input (default thunk)
  "Call THUNK, but let pending input abort it; then return DEFAULT.
Forcing font-lock over the source buffer can hit a pathological
matcher, and a background poll that will not yield turns one buffer's
bug into a frozen Emacs.  Any input -- a keystroke, \\[keyboard-quit]
-- ends THUNK.  Returns THUNK's value when it finishes uninterrupted,
DEFAULT when input interrupts it or is already pending."
  (let ((r (while-no-input (funcall thunk))))
    (if (memq r '(t nil)) default r)))

(defun canvas-minimap--fontify (beg end)
  "Make sure faces exist between BEG and END before we read them.
The forced fontification yields to input, so a runaway font-lock
matcher over the source buffer cannot wedge the poll."
  (when (and font-lock-mode (not (get-text-property beg 'fontified)))
    (ignore-errors
      (canvas-minimap--yield-to-input
       nil (lambda () (font-lock-ensure beg end))))))

(defun canvas-minimap--window-end (win buf)
  "Last visible position of WIN, forcing font-lock only if input allows.
`window-end' with UPDATE fontifies the visible region; a keystroke
aborts that and we fall back to the cached end, or BUF's `point-max',
so the poll never wedges on a pathological matcher."
  (or (canvas-minimap--yield-to-input nil (lambda () (window-end win t)))
      (window-end win)
      (with-current-buffer buf (point-max))))

;;;; The layout strip

;; A plan of the frame's windows across the top of the map, with the one
;; the map is drawing filled in.  A minimap says a great deal about
;; where you are in a buffer and nothing at all about which window it
;; belongs to; on a frame carrying three of them, that is the question a
;; picture answers faster than any label.
;;
;; Off unless `canvas-minimap-layout-height' asks for it, and even then
;; not until the frame is split: on a frame with one window there is
;; nothing to draw that the map does not already say, and the rows are
;; better spent on the buffer.  `canvas-minimap-layout-always' draws it
;; regardless.

(defun canvas-minimap--layout-wanted-p (frame)
  "Non-nil if FRAME's plan is worth drawing.
It is when there are windows to tell apart, or when
`canvas-minimap-layout-always' says to draw it anyway."
  (or canvas-minimap-layout-always
      (cdr (canvas-minimap--layout-windows frame))))

(defun canvas-minimap--layout-height (width scale frame)
  "Canvas pixel rows the layout strip takes on a WIDTH-wide canvas at SCALE.
None unless the strip is asked for and FRAME's plan is worth drawing."
  (let ((h canvas-minimap-layout-height))
    (cond ((not (canvas-minimap--layout-wanted-p frame)) 0)
          ((eq h 'auto) (max (* scale 8) (/ width 4)))
          ((and (integerp h) (> h 0)) (* scale h))
          (t 0))))

(defun canvas-minimap--layout-frame (st)
  "The frame ST is drawing a window of, or nil."
  (let ((win (canvas-minimap--state-window st)))
    (and (window-live-p win) (window-frame win))))

(defun canvas-minimap--layout-windows (frame)
  "Windows of FRAME the plan draws: the ones you can work in.
The maps are left out.  A minimap is furniture rather than a pane of
the layout, and drawing one as a pane invites a click that cannot go
anywhere."
  (seq-remove #'canvas-minimap--minimap-window-p
              (window-list frame 'no-mini)))

(defun canvas-minimap--layout-area (st)
  "Where the plan is laid out in ST's strip, as (X WIDTH HEIGHT).
Set so the outermost panes' borders land on the very columns the map's
text starts and ends at.  The strip and the picture under it are one
thing seen at two scales, and two edges that nearly line up read as a
mistake; the gutter is left to itself, since it is not part of the
buffer either."
  (let ((pad (canvas-minimap--state-scale st))
        (tx0 (canvas-minimap--state-text-x0 st))
        (tx1 (canvas-minimap--state-text-x1 st)))
    (list (- tx0 pad)
          (max 1 (+ (- tx1 tx0) (* 2 pad)))
          (max 1 (canvas-minimap--state-top st)))))

(defun canvas-minimap--layout-scale (st frame)
  "How to map FRAME pixels into ST's strip, as (OX OY FW FH W TOP), or nil.
Measured over the windows the plan draws rather than over the frame, so
the plan fills the strip: what the maps and the tool bar take is not
part of the layout being drawn."
  (let (x0 y0 x1 y1)
    (dolist (win (canvas-minimap--layout-windows frame))
      (let ((e (window-pixel-edges win)))
        (setq x0 (if x0 (min x0 (nth 0 e)) (nth 0 e))
              y0 (if y0 (min y0 (nth 1 e)) (nth 1 e))
              x1 (if x1 (max x1 (nth 2 e)) (nth 2 e))
              y1 (if y1 (max y1 (nth 3 e)) (nth 3 e)))))
    (when x0
      (list x0 y0 (max 1 (- x1 x0)) (max 1 (- y1 y0))
            (canvas-minimap--state-width st) (canvas-minimap--state-top st)))))

(defvar canvas-minimap--ace-asked nil
  "Whether ace-window has been asked for once already.")

(defun canvas-minimap--layout-keys ()
  "Alist of window to the key `ace-window' would select it with, or nil.
Read out of ace-window rather than worked out again here: which window
gets which key is its business, and a label that disagrees with what
you have to press is worse than no label at all.

Which means ace-window has to be loaded, and it is usually autoloaded
-- so the plan would go unlabelled until the first time you called for
a window, which is exactly when you no longer need the labels.  It is
asked for once, the first time a plan is drawn, and not again if it is
not installed."
  (when canvas-minimap-layout-labels
    (unless (or canvas-minimap--ace-asked (featurep 'ace-window))
      (setq canvas-minimap--ace-asked t)
      (require 'ace-window nil t))
    (when (and (fboundp 'aw-window-list)
               (boundp 'aw-keys))
      (let ((keys (symbol-value 'aw-keys))
            (wins (ignore-errors (funcall 'aw-window-list)))
            (res nil))
        ;; More windows than keys and ace-window starts building
        ;; sequences of them; one pane cannot carry that, so it carries
        ;; nothing.
        (when (and wins (<= (length wins) (length keys)))
          (dolist (win wins (nreverse res))
            (push (cons win (pop keys)) res)))))))

(defun canvas-minimap--label-size (top)
  "Rows and columns a label is drawn at in a TOP-tall strip, as a cons."
  (let ((rows (max 6 (/ top 4))))
    (cons rows (max 3 (/ rows 2)))))

(defun canvas-minimap--draw-label (st ch x0 y0 x1 y1 lut)
  "Draw CH through LUT in the middle of the box X0,Y0 to X1,Y1.
Nothing is drawn in a pane with no room for it: half a character is
worse than none."
  (pcase-let* ((`(,rows . ,cols) (canvas-minimap--label-size
                                  (canvas-minimap--state-top st))))
    (when (and (< (+ cols 2) (- x1 x0)) (< (+ rows 2) (- y1 y0)))
      (let* ((data (canvas-minimap--state-data st))
             (w (canvas-minimap--state-width st))
             (cells (aref (canvas-minimap--glyph-table
                           rows cols (canvas-minimap--font-family))
                          (if (< ch 128) ch 128)))
             (ox (+ x0 (/ (- (- x1 x0) cols) 2)))
             (oy (+ y0 (/ (- (- y1 y0) rows) 2)))
             (dy 0))
        (while (< dy rows)
          (let ((base (+ (* (+ oy dy) w) ox))
                (off (* dy cols))
                (dx 0))
            (while (< dx cols)
              (let ((lvl (aref cells (+ off dx))))
                (unless (eq lvl 0)
                  (aset data (+ base dx) (aref lut lvl))))
              (setq dx (1+ dx))))
          (setq dy (1+ dy)))))))

(defun canvas-minimap--render-layout (st)
  "Draw the frame's window plan across the top of ST's canvas.
Repainted only when the plan or the filled window changed, which the
recorded signature says: window layouts do not move on a timer, and this
is the one part of the canvas that has nothing to do with the buffer."
  (let ((top (canvas-minimap--state-top st))
        (win (canvas-minimap--state-window st))
        (frame (canvas-minimap--layout-frame st)))
    (when (and frame (> top 0))
      (let* ((keys (canvas-minimap--layout-keys))
             (sig (list win canvas-minimap-layout-color
                        canvas-minimap-layout-alpha
                        canvas-minimap-layout-outline-color
                        canvas-minimap-layout-background
                        keys
                        (mapcar #'window-pixel-edges
                                (canvas-minimap--layout-windows frame))))
             (scale (canvas-minimap--layout-scale st frame)))
        (unless (or (null scale)
                    (equal sig (canvas-minimap--state-layout st)))
          (setf (canvas-minimap--state-layout st) sig)
          (pcase-let* ((`(,ox ,oy ,fw ,fh ,w ,_) scale)
                       (data (canvas-minimap--state-data st))
                       (pad (canvas-minimap--state-scale st))
                       (bg (canvas-minimap--state-bg st))
                       (fg (canvas-minimap--state-fg st))
                       (back (or (canvas-minimap--rgb
                                  canvas-minimap-layout-background)
                                 bg))
                       (line (or (canvas-minimap--rgb
                                  canvas-minimap-layout-outline-color)
                                 (canvas-minimap--blend back fg 0.38)))
                       ;; The cursor's colour, not the region's: a theme
                       ;; is free to make the region a shade of the
                       ;; background, and a pane that is only a shade
                       ;; brighter than its neighbours says nothing.
                       (fill (canvas-minimap--blend
                              back
                              (or (canvas-minimap--rgb
                                   (or canvas-minimap-layout-color
                                       canvas-minimap-point-color
                                       (frame-parameter frame 'cursor-color)))
                                  fg)
                              (min 1.0 (max 0.0 canvas-minimap-layout-alpha))))
                       (bgpix (apply #'canvas-minimap--argb back))
                       (edge (apply #'canvas-minimap--argb line))
                       (lit (apply #'canvas-minimap--argb fill))
                       ;; A label reads out of the pane it is on: ink on
                       ;; the background for an outline, and knocked out
                       ;; of the fill for the pane being drawn.  Darker
                       ;; than the outline it sits in -- the outline is
                       ;; structure, the label is something to read.
                       (ink (canvas-minimap--make-lut
                             back (canvas-minimap--blend back fg 0.75)))
                       (knockout (canvas-minimap--make-lut fill back)))
            (canvas-minimap--fill-cell data w 0 top 0 w bgpix)
            (dolist (this (canvas-minimap--layout-windows frame))
              (pcase-let* ((`(,bx ,iw ,ih) (canvas-minimap--layout-area st))
                           (e (window-pixel-edges this))
                           (x0 (+ bx pad (/ (* (- (nth 0 e) ox) iw) fw)))
                           (y0 (+ pad (/ (* (- (nth 1 e) oy) ih) fh)))
                           (x1 (min w (- (+ bx (/ (* (- (nth 2 e) ox) iw) fw))
                                         pad)))
                           (y1 (min top (- (/ (* (- (nth 3 e) oy) ih) fh)
                                           pad))))
                (when (and (< x0 x1) (< y0 y1))
                  ;; Filled or outlined rather than one colour against
                  ;; another, so which pane is current survives whatever
                  ;; the theme does to the colours.
                  (canvas-minimap--fill-cell
                   data w y0 (- y1 y0) x0 x1
                   (if (eq this win) lit edge))
                  (when (and (not (eq this win))
                             (< (+ x0 pad) (- x1 pad))
                             (< (+ y0 pad) (- y1 pad)))
                    (canvas-minimap--fill-cell
                     data w (+ y0 pad) (- y1 y0 pad pad)
                     (+ x0 pad) (- x1 pad) bgpix))
                  (when-let* ((key (cdr (assq this keys))))
                    (canvas-minimap--draw-label
                     st key x0 y0 x1 y1
                     (if (eq this win) knockout ink))))))))))))

(defun canvas-minimap--layout-window-at (st x y)
  "Live window ST's layout strip draws at canvas position X, Y, or nil.
Nil for a point below the strip, and for the maps themselves: a window
you cannot work in is not one to be sent to."
  (let ((frame (canvas-minimap--layout-frame st)))
    (when (and frame (> (canvas-minimap--state-top st) 0)
               (< y (canvas-minimap--state-top st)))
      (pcase-let* ((`(,ox ,oy ,fw ,fh ,_w ,_top)
                    (or (canvas-minimap--layout-scale st frame)
                        (list 0 0 1 1 1 1)))
                   ;; Read back through the same mapping the plan is
                   ;; drawn with, so a click lands where it looks.
                   (`(,bx ,iw ,ih) (canvas-minimap--layout-area st))
                   (at (window-at-x-y
                        (+ ox (/ (* (min (1- iw) (max 0 (- x bx))) fw) iw))
                        (+ oy (/ (* (min (1- ih) (max 0 y)) fh) ih))
                        frame)))
        (and (window-live-p at)
             (not (canvas-minimap--minimap-window-p at))
             at)))))

;;;; Scrolling the rendered slice

(defun canvas-minimap--copy-slot (vec base from to n)
  "Copy N pixels of slot FROM over slot TO within VEC.
BASE is where slot 0 starts, which is past the layout strip."
  (let ((s (+ base (* from n))) (d (+ base (* to n))) (i 0))
    (while (< i n)
      (aset vec (+ d i) (aref vec (+ s i)))
      (setq i (1+ i)))))

(defun canvas-minimap--shift (st delta)
  "Move ST's rendered content by DELTA slots; slot I takes slot I+DELTA.
Only the slots that scrolled into view are invalidated, so a scroll
costs a block copy plus a handful of freshly rasterized lines."
  (canvas-minimap--undecorate-all st)
  (let* ((rows (canvas-minimap--state-rows st))
         (data (canvas-minimap--state-data st))
         (cookies (canvas-minimap--state-cookies st))
         (parts (canvas-minimap--state-parts st))
         (gutter (canvas-minimap--state-gutter st))
         (n (canvas-minimap--state-slot-pixels st))
         (base (* (canvas-minimap--state-top st)
                  (canvas-minimap--state-width st))))
    (if (>= (abs delta) rows)
        (progn (fillarray cookies 'unknown) (fillarray parts -1)
               (fillarray gutter 'unknown))
      (if (> delta 0)
          (let ((i 0) (last (- rows delta)))
            (while (< i last)
              (canvas-minimap--copy-slot data base (+ i delta) i n)
              (aset cookies i (aref cookies (+ i delta)))
              (aset parts i (aref parts (+ i delta)))
              (aset gutter i (aref gutter (+ i delta)))
              (setq i (1+ i)))
            (while (< i rows)
              (aset cookies i 'unknown)
              (aset parts i -1)
              (aset gutter i 'unknown)
              (setq i (1+ i))))
        (let* ((d (- delta))
               (i (1- rows)))
          (while (>= i d)
            (canvas-minimap--copy-slot data base (- i d) i n)
            (aset cookies i (aref cookies (- i d)))
            (aset parts i (aref parts (- i d)))
            (aset gutter i (aref gutter (- i d)))
            (setq i (1- i)))
          (while (>= i 0)
            (aset cookies i 'unknown)
            (aset parts i -1)
            (aset gutter i 'unknown)
            (setq i (1- i))))))))

;;;; Decoration: viewport box, point marker and match marks

(defsubst canvas-minimap--deco-want (i vp0 vp1 pslot hits)
  "Which decoration slot I should be carrying.
A bit each: 1 the viewport tint, 2 the point marker, 4 a match mark, 8
the top of the viewport outline, 16 its bottom, 32 its sides."
  (let ((in (and vp0 vp1 (>= i vp0) (<= i vp1)))
        (tint (memq canvas-minimap-viewport-style '(tint both)))
        (line (memq canvas-minimap-viewport-style '(outline both))))
    (logior (if (and in tint) 1 0)
            (if (eql i pslot) 2 0)
            (if (and hits (aref hits i)) 4 0)
            (if (and in line (eql i vp0)) 8 0)
            (if (and in line (eql i vp1)) 16 0)
            (if (and in line) 32 0))))

(defun canvas-minimap--save-slot (st slot)
  "Stash SLOT's text pixels so decoration can be lifted off again."
  (let* ((data (canvas-minimap--state-data st))
         (save (canvas-minimap--state-save-buf st))
         (w (canvas-minimap--state-width st))
         (lh (canvas-minimap--state-lh st))
         (x0 (canvas-minimap--state-text-x0 st))
         (x1 (canvas-minimap--state-text-x1 st))
         (n (- x1 x0))
         (off (* slot (canvas-minimap--state-text-slot-pixels st)))
         (y (canvas-minimap--slot-y st slot))
         (dy 0))
    (while (< dy lh)
      (let ((base (+ (* (+ y dy) w) x0))
            (dst (+ off (* dy n)))
            (i 0))
        (while (< i n)
          (aset save (+ dst i) (aref data (+ base i)))
          (setq i (1+ i))))
      (setq dy (1+ dy)))))

(defun canvas-minimap--restore-slot (st slot)
  "Put SLOT's text pixels back the way they were before decoration."
  (let* ((data (canvas-minimap--state-data st))
         (save (canvas-minimap--state-save-buf st))
         (w (canvas-minimap--state-width st))
         (lh (canvas-minimap--state-lh st))
         (x0 (canvas-minimap--state-text-x0 st))
         (x1 (canvas-minimap--state-text-x1 st))
         (n (- x1 x0))
         (off (* slot (canvas-minimap--state-text-slot-pixels st)))
         (y (canvas-minimap--slot-y st slot))
         (dy 0))
    (while (< dy lh)
      (let ((base (+ (* (+ y dy) w) x0))
            (src (+ off (* dy n)))
            (i 0))
        (while (< i n)
          (aset data (+ base i) (aref save (+ src i)))
          (setq i (1+ i))))
      (setq dy (1+ dy)))))

(defun canvas-minimap--tint-slot (st slot tr tg tb)
  "Blend SLOT's text columns through the channel tables TR, TG and TB."
  (let* ((data (canvas-minimap--state-data st))
         (w (canvas-minimap--state-width st))
         (lh (canvas-minimap--state-lh st))
         (x0 (canvas-minimap--state-text-x0 st))
         (x1 (canvas-minimap--state-text-x1 st))
         (y0 (canvas-minimap--slot-y st slot))
         (dy 0))
    (while (< dy lh)
      (let ((base (* (+ y0 dy) w))
            (x x0))
        (while (< x x1)
          (let ((p (aref data (+ base x))))
            (aset data (+ base x)
                  (logior #xFF000000
                          (ash (aref tr (logand (ash p -16) #xFF)) 16)
                          (ash (aref tg (logand (ash p -8) #xFF)) 8)
                          (aref tb (logand p #xFF)))))
          (setq x (1+ x))))
      (setq dy (1+ dy)))))

(defun canvas-minimap--apply-deco (st slot flags)
  "Paint FLAGS' decoration onto SLOT's text columns.
The match mark goes on first: a matched line inside the viewport is
still inside it, and the viewport tint belongs over the top of
whatever the line is otherwise showing."
  (let* ((data (canvas-minimap--state-data st))
         (w (canvas-minimap--state-width st))
         (lh (canvas-minimap--state-lh st))
         (height (canvas-minimap--state-height st))
         (x0 (canvas-minimap--state-text-x0 st))
         (x1 (canvas-minimap--state-text-x1 st))
         (y0 (canvas-minimap--slot-y st slot)))
    (when (/= 0 (logand flags 4))
      (canvas-minimap--tint-slot st slot
                                 (canvas-minimap--state-match-r st)
                                 (canvas-minimap--state-match-g st)
                                 (canvas-minimap--state-match-b st)))
    (when (/= 0 (logand flags 1))
      (canvas-minimap--tint-slot st slot
                                 (canvas-minimap--state-tint-r st)
                                 (canvas-minimap--state-tint-g st)
                                 (canvas-minimap--state-tint-b st)))
    (let ((pad (canvas-minimap--state-scale st))
          (pix (canvas-minimap--state-vp-line-pix st)))
      (when (/= 0 (logand flags 32))
        (canvas-minimap--fill-cell data w y0 lh x0 (min x1 (+ x0 pad)) pix)
        (canvas-minimap--fill-cell data w y0 lh (max x0 (- x1 pad)) x1 pix))
      (when (/= 0 (logand flags 8))
        (canvas-minimap--fill-cell data w y0 pad x0 x1 pix))
      (when (/= 0 (logand flags 16))
        (canvas-minimap--fill-cell data w (- (+ y0 lh) pad) pad x0 x1 pix)))
    (when (/= 0 (logand flags 2))
      (let* ((ph (canvas-minimap--state-ph st))
             (r0 (+ y0 (/ (max 0 (- lh ph)) 2)))
             (r1 (min height (+ r0 ph))))
        (canvas-minimap--fill-cell data w r0 (- r1 r0) x0 x1
                                   (canvas-minimap--state-point-pix st))))))

(defun canvas-minimap--undecorate-all (st)
  "Lift every bit of decoration off, leaving the text render bare."
  (let ((deco (canvas-minimap--state-deco st))
        (rows (canvas-minimap--state-rows st))
        (i 0))
    (while (< i rows)
      (unless (eql 0 (aref deco i))
        (canvas-minimap--restore-slot st i)
        (aset deco i 0))
      (setq i (1+ i)))))

(defun canvas-minimap--decorate (st vp0 vp1 pslot hits)
  "Bring decoration up to date for viewport VP0..VP1 and point slot PSLOT.
HITS flags the slots holding a line an active completion is matching.
Return non-nil if any pixel was touched.
Only slots whose decoration actually changed are touched, so moving
point costs two slots rather than a repaint of the whole viewport band."
  (let* ((deco (canvas-minimap--state-deco st))
         (rows (canvas-minimap--state-rows st))
         (vp0 (and vp0 (max 0 vp0)))
         (vp1 (and vp1 (min (1- rows) vp1)))
         (pslot (and canvas-minimap-show-point pslot))
         (painted nil)
         (i 0))
    (while (< i rows)
      (let ((want (canvas-minimap--deco-want i vp0 vp1 pslot hits))
            (have (aref deco i)))
        (unless (eql want have)
          (unless (eql 0 have) (canvas-minimap--restore-slot st i))
          (unless (eql 0 want)
            (canvas-minimap--save-slot st i)
            (canvas-minimap--apply-deco st i want))
          (aset deco i want)
          (setq painted t)))
      (setq i (1+ i)))
    painted))

;;;; Change tracking

(defun canvas-minimap--invalidate-lines (st from to)
  "Drop the cookies of any slot showing a buffer line in [FROM, TO].
Scanned rather than computed: with invisible text stepped over, a slot
is not its start plus its index."
  (when (and from to)
    (let ((cookies (canvas-minimap--state-cookies st))
          (rows (canvas-minimap--state-rows st))
          (i 0))
      (while (< i rows)
        (let ((c (aref cookies i)))
          (when (and (integerp c) (<= from c) (<= c to))
            (aset cookies i 'unknown)))
        (setq i (1+ i))))))

(defun canvas-minimap--line-of (buf pos)
  "Number of the line POS falls on in BUF, counted over the whole buffer.
The map is drawn widened, so the lines it is asked about have to be
numbered widened too.  POS is clamped first: an overlay's span is
remembered from one scan to the next, and the text under it can be gone
by then."
  (with-current-buffer buf
    (save-restriction
      (widen)
      (line-number-at-pos (max (point-min) (min pos (point-max)))))))

(defun canvas-minimap--invalidate-span (st buf from to)
  "Invalidate the slots covering buffer positions FROM to TO of BUF."
  (canvas-minimap--invalidate-lines st
                                    (canvas-minimap--line-of buf (min from to))
                                    (canvas-minimap--line-of buf (max from to))))

(defun canvas-minimap--highlight-overlay-p (ov win)
  "Non-nil if OV highlights text or appends content in WIN."
  (and (or (overlay-get ov 'face) (overlay-get ov 'after-string))
       (overlay-start ov)
       (let ((ow (overlay-get ov 'window)))
         (or (null ow) (eq ow win)))))

(defun canvas-minimap--scan-overlays (st buf win)
  "Invalidate slots whose overlay highlighting or appended content changed.
Return non-nil if any.

Slots are re-rasterized when their text changes, which is no help for
highlighting that is laid over unchanged text: a region being dragged,
`hl-line' following point, a pulse fading out.  Comparing the overlays
against what was last drawn catches all of it without any package
needing to know about us.

Overlays have identity, so a moved one is not a delete plus an insert:
only the lines whose membership actually flipped are invalidated, and
dragging a selection stays two lines' work however long it grows."
  (let ((seen (canvas-minimap--state-overlays st))
        (fresh (make-hash-table :test 'eq))
        (beg (canvas-minimap--state-slice-beg st))
        (end (canvas-minimap--state-slice-end st))
        (changed nil))
    (when (and (marker-position beg) (marker-position end))
      (with-current-buffer buf
        (dolist (ov (overlays-in beg (max (marker-position end)
                                          (marker-position beg))))
          (when (canvas-minimap--highlight-overlay-p ov win)
            (let* ((os (overlay-start ov))
                   (oe (overlay-end ov))
                   (face (overlay-get ov 'face))
                   (after (overlay-get ov 'after-string))
                   (old (gethash ov seen)))
              (puthash ov (vector os oe face (and after (copy-sequence after))) fresh)
              (cond
               ((null old)
                (canvas-minimap--invalidate-span st buf os oe)
                (setq changed t))
               ((or (not (equal face (aref old 2)))
                    (not (equal-including-properties after (aref old 3))))
                (canvas-minimap--invalidate-span st buf
                                                 (min os (aref old 0))
                                                 (max oe (aref old 1)))
                (setq changed t))
               (t
                (unless (eql os (aref old 0))
                  (canvas-minimap--invalidate-span st buf os (aref old 0))
                  (setq changed t))
                (unless (eql oe (aref old 1))
                  (canvas-minimap--invalidate-span st buf oe (aref old 1))
                  (setq changed t)))))))
        (maphash (lambda (ov old)
                   (unless (gethash ov fresh)
                     (canvas-minimap--invalidate-span st buf
                                                      (aref old 0) (aref old 1))
                     (setq changed t)))
                 seen)))
    (setf (canvas-minimap--state-overlays st) fresh)
    changed))

(defun canvas-minimap--mark-dirty (from to)
  "Note that buffer lines FROM through TO need redrawing."
  (setq canvas-minimap--dirty
        (if canvas-minimap--dirty
            (cons (min from (car canvas-minimap--dirty))
                  (max to (cdr canvas-minimap--dirty)))
          (cons from to))))

(defun canvas-minimap--newlines (beg end)
  "How many newlines the text between BEG and END holds."
  (save-excursion
    (goto-char (min beg end))
    (let ((stop (max beg end)) (n 0))
      (while (search-forward "\n" stop t) (setq n (1+ n)))
      n)))

(defun canvas-minimap--before-change (beg end)
  "Remember how many newlines stand between BEG and END."
  (unless canvas-minimap--rendering
    (setq canvas-minimap--pending-lines
          (ignore-errors (canvas-minimap--newlines beg end)))))

(defun canvas-minimap--after-change (beg end _len)
  "Mark the lines touched by a change between BEG and END.
A change that alters the number of lines shifts every line below it, so
everything from there down is invalidated; an in-line edit is not."
  (unless canvas-minimap--rendering
    (let* ((buf (current-buffer))
           (before canvas-minimap--pending-lines)
           (after (ignore-errors (canvas-minimap--newlines beg end)))
           (l1 (canvas-minimap--line-of buf beg)))
      (setq canvas-minimap--pending-lines nil)
      (if (and before after (= before after))
          (canvas-minimap--mark-dirty l1 (canvas-minimap--line-of buf end))
        (canvas-minimap--mark-dirty l1 most-positive-fixnum)))))

;;;; Matching lines

;; `consult-line' and the rest of its family leave the buffer alone: the
;; lines they are matching exist only as completion candidates in a
;; minibuffer, and nothing about the search is visible in the text until
;; one of them is jumped to.  What they do leave is a buffer position on
;; every candidate, so asking the completion table what the current
;; input matches gives the lines back.
;;
;; Asked through the completion API rather than through any one
;; package's internals: the table, the input and the styles are the ones
;; the completion UI is itself matching with, so the marks agree with
;; the candidate list on screen whether that list is drawn by Vertico,
;; Icomplete or nothing at all.

(defvar canvas-minimap--match-cache nil
  "[MINIBUFFER INPUT PREDICATE NARROW CANDIDATES] of the last match.
Matching the table is the one costly step, and the same input is asked
about again on every poll and every command; keeping the last answer
means the work happens once per keystroke instead.

Dropped as soon as nothing is completing: the candidates hold on to
positions in a buffer, and through them to the buffer itself.")

(defun canvas-minimap--all-completions (mb input table pred)
  "Candidates of TABLE that INPUT matches, as minibuffer MB would match them.
Run in MB so that the completion styles in force there are the ones
used, and with lazy highlighting on, since the strings themselves are
never looked at -- only the position each one carries.

A half-typed regexp is a matching error rather than a bug, and there is
one on the way to most finished ones."
  (with-current-buffer mb
    (condition-case nil
        (let* ((completion-lazy-hilit t)
               ;; Bound, not merely set by the styles: the completion UI
               ;; leaves its own highlighter in here between computing
               ;; its candidates and drawing them.
               (completion-lazy-hilit-fn nil)
               (all (completion-all-completions input table pred (length input))))
          ;; The list `completion-all-completions' returns ends in the
          ;; base size rather than in nil.
          (when-let* ((tail (last all))) (setcdr tail nil))
          (and (null (nthcdr (max 1 canvas-minimap-match-limit) all)) all))
      (error nil))))

(defun canvas-minimap--location-candidates ()
  "Candidates the active minibuffer completion is matching, or nil.
Only a completion over buffer locations has anything to mark, which is
what the `consult-location' category means."
  (let* ((mw (and canvas-minimap-highlight-matches (active-minibuffer-window)))
         (mb (and mw (window-buffer mw)))
         (table (and mb (buffer-local-value 'minibuffer-completion-table mb)))
         (pred (and mb (buffer-local-value 'minibuffer-completion-predicate mb)))
         ;; Narrowing to another key leaves the predicate the object it
         ;; was and changes only what it reads, so the answer can go
         ;; stale without anything in the completion API saying so.
         (narrow (and mb (boundp 'consult--narrow)
                      (buffer-local-value 'consult--narrow mb)))
         (input (and table (with-current-buffer mb
                             (minibuffer-contents-no-properties)))))
    (if (not (and input (not (string-empty-p input))
                  (eq 'consult-location
                      (completion-metadata-get
                       (completion-metadata input table pred) 'category))))
        (setq canvas-minimap--match-cache nil)
      (let ((c canvas-minimap--match-cache))
        (if (and c (eq (aref c 0) mb) (equal (aref c 1) input)
                 (eq (aref c 2) pred) (eq (aref c 3) narrow))
            (aref c 4)
          (let ((cands (canvas-minimap--all-completions mb input table pred)))
            (setq canvas-minimap--match-cache (vector mb input pred narrow cands))
            cands))))))

(defun canvas-minimap--candidate-position (cand buf)
  "Position in BUF that completion candidate CAND stands for, or nil.
A `consult-location' candidate carries (MARKER . LINE), where MARKER is
still the cheap (BUFFER . POSITION) stand-in until something asks for a
real one.  A candidate belonging to some other buffer -- what
`consult-line-multi' is made of -- is not one of ours."
  (when (and (stringp cand) (> (length cand) 0))
    (let ((m (car-safe (get-text-property 0 'consult-location cand))))
      (cond
       ((consp m) (and (eq (car m) buf) (cdr m)))
       ((markerp m) (and (eq (marker-buffer m) buf) (marker-position m)))))))

(defun canvas-minimap--slot-at-pos (st pos rows)
  "Slot of ST drawing the line POS falls on, or nil if none is.
Searched over where each slot's line starts, which is the only record
of the slice that survives invisible text being stepped over: a match
inside a folded region lands on the visible line it is folded into."
  (let ((v (canvas-minimap--state-slot-pos st))
        (lo 0) (hi rows) (res nil))
    (while (< lo hi)
      (let* ((mid (/ (+ lo hi) 2))
             (p (aref v mid)))
        ;; Slots past the end of the buffer hold nil, and they are all
        ;; at the end, so nil compares as beyond every position.
        (if (and p (<= p pos))
            (setq res mid lo (1+ mid))
          (setq hi mid))))
    res))

(defun canvas-minimap--match-hits (st buf rows)
  "Vector of ROWS flags, t on every slot holding a matched line of BUF.
Nil when nothing is completing, or when nothing it matches is on the
part of the buffer the minimap is drawing."
  (when-let* ((cands (canvas-minimap--location-candidates))
              (beg (marker-position (canvas-minimap--state-slice-beg st)))
              (end (marker-position (canvas-minimap--state-slice-end st))))
    (let ((hits nil)
          ;; The slice ends at the start of the line after the last one
          ;; drawn, which is a line the minimap is not showing.
          (last (with-current-buffer buf
                  (save-restriction
                    (widen)
                    (if (= end (point-max)) end (1- end))))))
      (dolist (cand cands)
        (when-let* ((pos (canvas-minimap--candidate-position cand buf))
                    ((<= beg pos last))
                    (slot (canvas-minimap--slot-at-pos st pos rows)))
          (unless hits (setq hits (make-vector rows nil)))
          (aset hits slot t)))
      hits)))

;;;; The minimap window

(define-derived-mode canvas-minimap-image-mode special-mode "Minimap"
  "Major mode of the buffer a minimap's canvas is drawn in.
It exists to be recognized.  A window is filtered by what its buffer's
mode is -- it is what `ace-window' offers `aw-ignored-buffers' for, and
what anything else asking \"is this a window to send someone to\" has to
go on -- and a minimap is not somewhere to be sent.  The window
parameters say so too, but only to whoever reads them.")

(defvar aw-ignored-buffers)

;; ace-window reads `no-other-window' only for its own `ace-select-window',
;; not for the `ace-window' command most people bind, so the map turns up
;; as a candidate that cannot be jumped to -- and, since its whole buffer
;; is one character carrying the image, ace-window's label overlay lands
;; on that character and blanks the map for as long as it is choosing.
;; The mode is the filter that holds for every one of its commands.
(with-eval-after-load 'ace-window
  (add-to-list 'aw-ignored-buffers 'canvas-minimap-image-mode))

(defun canvas-minimap--new-buffer ()
  "A fresh buffer for one minimap's canvas."
  (with-current-buffer (generate-new-buffer " *canvas-minimap*")
    (canvas-minimap-image-mode)
    (buffer-disable-undo)
    (setq-local mode-line-format nil
                header-line-format nil
                cursor-type nil
                cursor-in-non-selected-windows nil
                truncate-lines t
                show-trailing-whitespace nil
                display-line-numbers nil
                left-fringe-width 0
                right-fringe-width 0
                left-margin-width 0
                right-margin-width 0)
    (current-buffer)))

(defun canvas-minimap--minimap-window-p (win)
  "Non-nil if WIN is a minimap rather than something to draw."
  (and (window-live-p win) (window-parameter win 'canvas-minimap)))

(defun canvas-minimap--windows (&optional frame)
  "Every live minimap window on FRAME."
  (seq-filter #'canvas-minimap--minimap-window-p
              (window-list (or frame (selected-frame)) 'no-mini)))

(defun canvas-minimap--window-for (target)
  "The minimap window belonging to TARGET, or nil."
  (seq-find (lambda (w) (eq (window-parameter w 'canvas-minimap) target))
            (canvas-minimap--windows (window-frame target))))

(defun canvas-minimap--frame-window (&optional frame)
  "The frame-level minimap window on FRAME, or nil."
  (seq-find (lambda (w) (eq (window-parameter w 'canvas-minimap) 'frame))
            (canvas-minimap--windows frame)))

(defun canvas-minimap--window-columns ()
  "Columns a minimap takes from the window it is split out of."
  (max 4 (ceiling canvas-minimap-width (max 1 (frame-char-width)))))

(defun canvas-minimap--wide-enough-p (win)
  "Non-nil if WIN can carry its own minimap and still be worth reading.
A window that already has one is judged on the width it has left, so the
answer does not flap as the minimap appears and disappears."
  (>= (- (window-body-width win)
         (if (canvas-minimap--window-for win)
             0
           (canvas-minimap--window-columns)))
      canvas-minimap-min-window-width))

(defun canvas-minimap--make-window (target)
  "Open a minimap window for TARGET, or for the frame when TARGET is nil."
  (let* ((buf (canvas-minimap--new-buffer))
         (win (if (null target)
                  (display-buffer-in-side-window
                   buf `((side . ,canvas-minimap-side)
                         (slot . 0)
                         (window-width . ,(canvas-minimap--window-columns))
                         (preserve-size . (t . nil))
                         (window-parameters
                          . ((no-other-window . t)
                             (no-delete-other-windows . t)
                             (mode-line-format . none)))))
                (when-let* ((w (ignore-errors
                                 (split-window target
                                               (- canvas-minimap-width)
                                               (if (eq canvas-minimap-side 'left)
                                                   'left 'right)
                                               t))))
                  (set-window-buffer w buf)
                  (set-window-parameter w 'no-other-window t)
                  (set-window-parameter w 'no-delete-other-windows t)
                  (set-window-parameter w 'mode-line-format 'none)
                  w))))
    (if (not (window-live-p win))
        (progn (kill-buffer buf) nil)
      (set-window-parameter win 'canvas-minimap (or target 'frame))
      ;; Whether it was born at the edge is what says it has been pushed
      ;; off one; a map that could never get there is left where it is.
      (set-window-parameter win 'canvas-minimap-edge
                            (and (null target)
                                 (window-at-side-p win canvas-minimap-side)))
      (set-window-dedicated-p win t)
      (window-preserve-size win t t)
      win)))

(defun canvas-minimap--stranded-p (mmwin)
  "Non-nil if the frame minimap MMWIN is no longer at the frame's edge.
A side window belongs at the edge, and Emacs keeps it there for
anything that displays into the frame's main area.  Something that
splits the root window itself instead -- shackle's `:align' does, and
it is not alone -- makes its new window a sibling of everything, the
side window included, and leaves the map stranded between two ordinary
windows.  A window cannot be moved, so the way back is to build it
again; this also picks up `canvas-minimap-side' being changed under a
map that is already up."
  (and (eq (window-parameter mmwin 'canvas-minimap) 'frame)
       (window-parameter mmwin 'canvas-minimap-edge)
       (not (window-at-side-p mmwin canvas-minimap-side))))

(defun canvas-minimap--destroy (mmwin)
  "Take MMWIN down and forget what it was drawing."
  (let ((buf (and (window-live-p mmwin) (window-buffer mmwin))))
    (remhash mmwin canvas-minimap--states)
    (when (window-live-p mmwin)
      (set-window-dedicated-p mmwin nil)
      (ignore-errors (delete-window mmwin)))
    (when (buffer-live-p buf) (kill-buffer buf))))

(defun canvas-minimap--show-image (mmwin image)
  "Put IMAGE in MMWIN's buffer."
  (with-current-buffer (window-buffer mmwin)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (propertize " " 'display image
                          'keymap canvas-minimap-image-map
                          'pointer 'arrow)))))

(defun canvas-minimap--hide (&optional frame)
  "Take every minimap on FRAME down."
  (mapc #'canvas-minimap--destroy (canvas-minimap--windows frame)))

(defun canvas-minimap--apply-width (mmwin)
  "Resize MMWIN so its body is `canvas-minimap-width' pixels wide."
  (let ((delta (- canvas-minimap-width (window-body-width mmwin t))))
    (unless (zerop delta)
      ;; The size is preserved to keep other windows from squeezing it,
      ;; which also means it has to be let go of to resize deliberately.
      (window-preserve-size mmwin t nil)
      (ignore-errors (window-resize mmwin delta t nil t))
      (window-preserve-size mmwin t t))))

(defun canvas-minimap-set-width (width)
  "Set the minimap to WIDTH pixels wide."
  (interactive (list (read-number "Minimap width (pixels): "
                                  canvas-minimap-width)))
  (setq canvas-minimap-width (max 16 width))
  (canvas-minimap--update))

(defun canvas-minimap-widen (&optional step)
  "Widen the minimap by STEP pixels, `canvas-minimap-width-step' by default."
  (interactive)
  (canvas-minimap-set-width (+ canvas-minimap-width
                               (or step canvas-minimap-width-step))))

(defun canvas-minimap-narrow (&optional step)
  "Narrow the minimap by STEP pixels, `canvas-minimap-width-step' by default."
  (interactive)
  (canvas-minimap-set-width (- canvas-minimap-width
                               (or step canvas-minimap-width-step))))

;;;; Update

(defun canvas-minimap--eligible-p (win buf)
  "Non-nil if WIN showing BUF should get a minimap."
  (and (window-live-p win)
       (buffer-live-p buf)
       ;; A frame can be a terminal even when the session is graphical,
       ;; and a canvas is worth nothing there.
       (display-graphic-p (window-frame win))
       (not (window-parameter win 'window-side))
       (not (minibufferp buf))
       (with-current-buffer buf
         (and (not (derived-mode-p canvas-minimap-exclude-modes))
              (not (string-prefix-p " " (buffer-name)))))))

(defun canvas-minimap--line-visible-p ()
  "Non-nil if the line point is on has anything on it the display shows.
Asked of the whole line rather than of its first character: an org link
hides its brackets, so a line that opens with one begins invisible and
is very much still there."
  (let ((end (line-end-position))
        (pos (point))
        (visible nil))
    (while (and (not visible) (< pos end))
      (if (invisible-p pos)
          (setq pos (next-single-char-property-change pos 'invisible nil end))
        (setq visible t)))
    (or visible (= (point) end))))

(defun canvas-minimap--forward-visible-line ()
  "Move to the start of the next visible line.
Return the number of buffer lines crossed, or nil at end of buffer.
Text the display is not showing -- a folded org subtree, a collapsed
magit section -- is not a line of the minimap either, so it is stepped
over rather than drawn."
  (let ((from (point)))
    (forward-line 1)
    (while (and (not (eobp)) (not (canvas-minimap--line-visible-p)))
      (goto-char (next-single-char-property-change (point) 'invisible))
      (unless (bolp) (forward-line 1)))
    (and (not (eobp)) (count-lines from (point)))))

(defun canvas-minimap--back-visible-line ()
  "Move to the start of the previous visible line.  Return nil at bob."
  (if (bobp)
      nil
    (forward-line -1)
    (while (and (not (bobp)) (not (canvas-minimap--line-visible-p)))
      (goto-char (previous-single-char-property-change (point) 'invisible))
      (forward-line 0))
    t))

(defun canvas-minimap--slot-of-line (st line &optional default)
  "Slot currently showing buffer LINE, or DEFAULT.
Read off what was last drawn, which is the only thing that knows where
a line ended up once invisible text is being stepped over."
  (or (and line (gethash line (canvas-minimap--state-slot-of st)))
      default))

(defun canvas-minimap--slice-start (win rows total wstart vis)
  "Buffer line the minimap's first slot should show.
WIN shows VIS lines starting at line WSTART of a TOTAL-line buffer, and
the minimap has ROWS to draw them in.  The slice tracks the window
proportionally, so the minimap thumb walks the whole buffer."
  (ignore win)
  (let ((lead (if (<= total rows)
                  most-positive-fixnum   ; short buffer: back up to the top
                (let* ((span (max 1 (- total (min vis rows))))
                       (frac (min 1.0 (max 0.0 (/ (float (1- wstart)) span)))))
                  (max 0 (round (* frac (max 0 (- rows (min vis rows))))))))))
    ;; Back up LEAD *visible* lines from the window's first line, so the
    ;; slice is measured in the lines the minimap will actually draw.
    (save-excursion
      (goto-char (point-min))
      (forward-line (1- wstart))
      (let ((n 0))
        (while (and (< n lead) (canvas-minimap--back-visible-line))
          (setq n (1+ n))))
      (line-number-at-pos (point)))))

(defvar canvas-minimap--glide-timer nil
  "Timer for the next frame of a glide, or nil when the map has settled.")

(defvar canvas-minimap--dragging nil
  "Bound while the map is being scrubbed, where a glide would be a lag.")

(defun canvas-minimap--glide (st goal fresh)
  "Line ST should draw in slot 0 now, on its way to GOAL.
FRESH says the map is not showing what it was a moment ago -- another
buffer, a rebuilt canvas -- and so has nowhere to glide from.

Each frame covers a fraction of what is left rather than a step of a
planned path.  That needs no record of when the glide began and
retargets on its own: a second jump while the first is still running is
just a new distance to cover, and the ease-out falls out of it."
  (let ((from (canvas-minimap--state-start st)))
    (if (or (not canvas-minimap-smooth-scroll)
            fresh
            canvas-minimap--dragging
            (null from)
            (< (abs (- goal from))
               (max 2 canvas-minimap-smooth-scroll-threshold)))
        goal
      (let* ((frac (min 1.0 (max 0.05 canvas-minimap-smooth-scroll-step)))
             (sign (if (> goal from) 1 -1))
             (left (min (abs (- goal from))
                        (max 1 canvas-minimap-smooth-scroll-distance)))
             (step (max 1 (round (* left frac)))))
        (if (>= step left)
            goal
          (unless canvas-minimap--glide-timer
            (setq canvas-minimap--glide-timer
                  (run-with-timer canvas-minimap-smooth-scroll-interval nil
                                  #'canvas-minimap--glide-frame)))
          (- goal (* sign (- left step))))))))

(defun canvas-minimap--glide-frame ()
  "Draw the next frame of a glide."
  (setq canvas-minimap--glide-timer nil)
  (when canvas-minimap-mode (canvas-minimap--update)))

(defun canvas-minimap--last-line-slot (st rows)
  "The last of ST\'s ROWS slots holding a line, or nil if none does."
  (let ((cookies (canvas-minimap--state-cookies st))
        (i (1- rows)))
    (while (and (>= i 0) (not (integerp (aref cookies i))))
      (setq i (1- i)))
    (and (>= i 0) i)))

(defun canvas-minimap--viewport-slots (st wstart wend rows)
  "Slots ST is drawing the window lines WSTART to WEND on, as a cons, or nil.
An end the map is not drawing clips to the edge it ran off, which at the
bottom is the last line drawn rather than the last row: a window sitting
at the end of a buffer runs past it, and the rows under a short buffer
hold nothing to be in the viewport.  A viewport the map is nowhere near
-- which is what the middle of a glide looks like -- gets no band at
all, rather than one covering everything."
  (let ((s0 (canvas-minimap--slot-of-line st wstart))
        (s1 (canvas-minimap--slot-of-line st wend)))
    (cond ((and s0 s1) (cons s0 s1))
          (s0 (cons s0 (or (canvas-minimap--last-line-slot st rows) s0)))
          (s1 (cons 0 s1)))))

(defun canvas-minimap--image-spec (display)
  "The image in a DISPLAY property, or nil.
The property can be the image itself or a list carrying it, the way a
fringe indicator can."
  (cond
   ((eq (car-safe display) 'image) display)
   ((consp display)
    (let ((l display) res)
      (while (and (consp l) (not res))
        (setq res (canvas-minimap--image-spec (car l))
              l (cdr l)))
      res))))

(defun canvas-minimap--words-outside-p (beg end from to)
  "Non-nil if the line BEG to END has words on it outside FROM to TO."
  (or (save-excursion
        (goto-char beg)
        (let ((stop (max beg (min end from))))
          (skip-chars-forward " \t" stop)
          (< (point) stop)))
      (save-excursion
        (goto-char (min end (max beg to)))
        (skip-chars-forward " \t" end)
        (< (point) end))))

(defun canvas-minimap--after-image (beg end win)
  "Image displayed below line BEG..END, as (SPEC . LEADING-ROWS).
Look in overlay after-strings for an image following a newline."
  (catch 'found
    (dolist (ov (overlays-in beg (min (point-max) (1+ end))))
      (let ((str (overlay-get ov 'after-string))
            (ow (overlay-get ov 'window))
            (anchor (overlay-end ov)))
        (when (and (stringp str) (or (null ow) (eq ow win))
                   (> anchor beg) (<= anchor end)
                   (not (overlay-get ov 'invisible)))
          (let ((pos 0))
            (while (< pos (length str))
              (let* ((img (canvas-minimap--image-spec
                           (get-text-property pos 'display str)))
                     (prefix (substring str 0 pos)))
                (when (and img (memq ?\n (string-to-list prefix)))
                  (throw 'found (cons img (cl-count ?\n prefix)))))
              (setq pos (next-single-property-change
                         pos 'display str (length str))))))))))

(defun canvas-minimap--line-image (st beg end win)
  "Picture standing in for the line BEG to END, as (SPEC SLOTS LEADING), or nil.
LEADING is the number of text rows preceding an appended image.
SLOTS is how many rows of the map the image stands as tall as, so that
the lines under it keep step with the window: a picture twenty lines
high drawn on one row would put the rest of the map out by nineteen.
Capped at half the map, since one picture should not take all of it.

SPEC is nil for an image that only sits on the line -- an icon at the
head of it, of the kind `svg-lib\' and the icon packages put there --
which leaves the words to be drawn as words on however many rows the
line takes.  A picture is one the display puts in place of the text; an
icon is one it puts beside it."
  (let ((pos beg) (img nil) (from beg) (to beg) (leading 0))
    (while (and (not img) (< pos end))
      (let ((next (next-single-char-property-change pos 'display nil end)))
        (when (setq img (canvas-minimap--image-spec
                         (get-char-property pos 'display win)))
          (setq from pos to next))
        (setq pos next)))
    ;; A line that is nothing but an image carries it on the newline.
    (unless img
      (when (setq img (canvas-minimap--image-spec
                       (get-char-property end 'display win)))
        (setq from end to end)))
    (unless img
      (when-let* ((appended (canvas-minimap--after-image beg end win)))
        (setq img (car appended) leading (cdr appended))))
    (when img
      (let ((size (ignore-errors (image-size img t)))
            (ch (max 1 (frame-char-height))))
        (when (and (consp size) (numberp (cdr size)) (> (cdr size) 0))
          (list (when (or (> leading 0)
                          (not (canvas-minimap--words-outside-p beg end from to)))
                  img)
                (+ leading
                   (max 1 (min (max 1 (/ (canvas-minimap--state-rows st) 2))
                               (ceiling (cdr size) ch))))
                leading))))))

(defvar canvas-minimap--thumbs (make-hash-table :test 'equal)
  "Downsampled images, keyed by file, its mtime, the size and the ground.
A key holds `pending' while the work is out, and `none' for a file that
could not be read, so nothing is asked for twice.")

(defun canvas-minimap--image-file (img)
  "The file IMG is drawn from, or nil for an image made out of data."
  (when-let* ((file (and (consp img) (plist-get (cdr img) :file))))
    (expand-file-name file)))

(defun canvas-minimap--thumb-parse (text w h)
  "Pixels of TEXT, W by H hex triples one row to a line, or nil if it is not."
  (let ((rows (split-string text "\n" t)))
    (when (and (= (length rows) h)
               (cl-every (lambda (row) (= (length row) (* 6 w))) rows))
      (let ((out (make-vector (* w h) 0))
            (y 0))
        (dolist (row rows out)
          (dotimes (x w)
            (aset out (+ (* y w) x)
                  (logior #xFF000000
                          (string-to-number
                           (substring row (* 6 x) (+ 6 (* 6 x))) 16))))
          (setq y (1+ y)))))))

(defun canvas-minimap--thumb-start (key file w h bg)
  "Ask for a W by H thumbnail of FILE over BG, to be filed under KEY."
  (let ((script (expand-file-name "tools/gen-image-thumb.py"
                                  canvas-minimap--directory)))
    (if (not (and (file-exists-p script) (executable-find "python3")))
        (puthash key 'none canvas-minimap--thumbs)
      (puthash key 'pending canvas-minimap--thumbs)
      (let ((stdout (generate-new-buffer " *canvas-minimap-thumb*"))
            (stderr (generate-new-buffer " *canvas-minimap-thumb-err*")))
        (condition-case nil
            (make-process
             :name "canvas-minimap-thumb"
             :buffer stdout :stderr stderr :noquery t
             :command (list "python3" script file
                            (number-to-string w) (number-to-string h)
                            (format "%06x" (logand bg #xFFFFFF)))
             :sentinel
             (lambda (proc _event)
               (when (memq (process-status proc) '(exit signal))
                 (let ((text (with-current-buffer stdout (buffer-string)))
                       (ok (eql (process-exit-status proc) 0)))
                   (when (buffer-live-p stdout) (kill-buffer stdout))
                   (when (buffer-live-p stderr) (kill-buffer stderr))
                   (puthash key
                            (or (and ok (canvas-minimap--thumb-parse text w h))
                                'none)
                            canvas-minimap--thumbs)
                   ;; It arrived with no command to hang a redraw off.
                   (canvas-minimap-refresh)))))
          (error
           (puthash key 'none canvas-minimap--thumbs)
           (when (buffer-live-p stdout) (kill-buffer stdout))
           (when (buffer-live-p stderr) (kill-buffer stderr))))))))

(defun canvas-minimap--thumb (file w h bg)
  "Pixels of FILE downsampled to W by H over BG, or nil if there are none yet.
The first ask starts the work and returns nil.  The map draws a plain
block meanwhile, and draws itself again when the answer arrives."
  (when (and canvas-minimap-image-thumbnails
             file (> w 0) (> h 0) (file-readable-p file))
    (let* ((key (list file
                      (file-attribute-modification-time (file-attributes file))
                      w h bg))
           (have (gethash key canvas-minimap--thumbs)))
      (cond ((vectorp have) have)
            (have nil)                  ; pending, or no good
            (t (canvas-minimap--thumb-start key file w h bg) nil)))))

(defvar canvas-minimap-thumbnail-functions nil
  "Functions asked for the picture of an image before its file is read.
Each is called with the image spec, the width and height wanted in
pixels, and the background as ARGB32, and returns a vector of width
times height ARGB32 pixels, row by row, or nil to pass.  A buffer that
draws its own canvas hands the map a scaled-down view of it this way,
and calls `canvas-minimap-picture-changed\' when the view moves.")

(defun canvas-minimap--image-thumb (img w h bg)
  "Pixels of IMG at W by H over BG, or nil while there are none yet.
A thumbnail function that answers is believed; otherwise the image's
file is downsampled in the background."
  (if-let* ((pixels (run-hook-with-args-until-success
                     'canvas-minimap-thumbnail-functions img w h bg)))
      (if (and (vectorp pixels) (= (length pixels) (* w h)))
          pixels
        (error "canvas-minimap: a thumbnail function gave no %dx%d vector" w h))
    (canvas-minimap--thumb (canvas-minimap--image-file img) w h bg)))

(defun canvas-minimap--picture-x (st img)
  "The pixel columns (X0 . X1) a picture of IMG takes in ST.
As wide as the image is on screen, at least a sliver, at most the text."
  (let* ((tx0 (canvas-minimap--state-text-x0 st))
         (tx1 (canvas-minimap--state-text-x1 st))
         (pad (canvas-minimap--state-scale st))
         (size (ignore-errors (image-size img t)))
         (xs (/ (float (canvas-minimap--state-cw st))
                (max 1 (canvas-minimap--state-char-w st)))))
    (cons tx0 (min tx1 (max (+ tx0 (* 2 pad))
                            (+ tx0 (round (* (if (consp size) (car size) 0) xs))))))))

(defvar canvas-minimap-picture-click-functions nil
  "Functions told of a click on a picture a thumbnail function drew.
Each is called with the image spec and where in the picture the click
fell, as fractions of its width and height from 0 to 1, and returns
non-nil once it has acted; the source window is then left alone.  A
drag calls them again as the mouse moves.")

(defun canvas-minimap--fraction (v lo hi)
  "Where V falls between LO and HI, from 0 to 1, clamped."
  (if (> hi lo)
      (min 1.0 (max 0.0 (/ (- v lo) (float (- hi lo)))))
    0.0))

(defun canvas-minimap--picture-of (st beg)
  "The picture on the source line starting at BEG, as (IMG SLOTS LEADING), or nil."
  (with-current-buffer (canvas-minimap--state-buffer st)
    (save-excursion
      (goto-char beg)
      (let ((picture (canvas-minimap--line-image st beg (line-end-position)
                                                 (canvas-minimap--state-window st))))
        (and (car picture) picture)))))

(defun canvas-minimap--picture-at (st x y)
  "The picture under canvas pixel X Y of ST, as (IMG FX FY), or nil.
FX and FY say where in the picture the point falls, as fractions."
  (let* ((lh (canvas-minimap--state-lh st))
         (slot (floor (- y (canvas-minimap--state-top st)) lh))
         (parts (canvas-minimap--state-parts st)))
    (when (and (< -1 slot (length parts)) (>= (aref parts slot) 0))
      (let ((top (- slot (aref parts slot)))
            (beg (aref (canvas-minimap--state-slot-pos st) slot)))
        (when-let* ((picture (and beg (canvas-minimap--picture-of st beg))))
          (pcase-let ((`(,x0 . ,x1) (canvas-minimap--picture-x st (car picture)))
                      (y0 (canvas-minimap--slot-y st (+ top (nth 2 picture)))))
            (when (>= y y0)
              (list (car picture)
                    (canvas-minimap--fraction x x0 x1)
                    (canvas-minimap--fraction
                     y y0 (+ y0 (* (- (nth 1 picture) (nth 2 picture)) lh)))))))))))

(defun canvas-minimap--picture-click (st x y)
  "Hand a click at canvas pixel X Y of ST to the owner of the picture there.
Non-nil when an owner took it."
  (when-let* ((picture (canvas-minimap--picture-at st x y)))
    (apply #'run-hook-with-args-until-success
           'canvas-minimap-picture-click-functions picture)))

(defun canvas-minimap--scrub (st xy)
  "Act on the minimap point XY, in window pixels.
A picture's owner gets the click, and the map is drawn again at once
so its picture follows a drag as the text's viewport does; otherwise
the source scrolls there."
  (let ((sc (canvas-minimap--state-scale st)))
    (if (canvas-minimap--picture-click st (* sc (car xy)) (* sc (cdr xy)))
        (canvas-minimap--update)
      (canvas-minimap--goto-y st (cdr xy)))))

(defun canvas-minimap-picture-changed (&optional buffer)
  "Draw BUFFER's lines again: a picture on one of them has changed."
  (with-current-buffer (or buffer (current-buffer))
    (canvas-minimap--mark-dirty 1 (max 1 (count-lines (point-min) (point-max))))))

(defun canvas-minimap--render-part (st slot beg end win part total img &optional leading)
  "Draw part PART of TOTAL of the line BEG to END into ST's SLOT.
A line of text is one part, drawn whole.  IMG is drawn as the picture
itself once one has been downsampled, and until then as a block the
size the image takes up.  LEADING counts text rows before the image."
  (setq leading (or leading 0))
  (if (or (null img) (< part leading))
      ;; The words go on the first row the line takes; the rest of the
      ;; rows an icon makes it stand as tall as are left empty.
      (if (zerop part)
          (canvas-minimap--render-slot st slot beg end win)
        (canvas-minimap--blank-slot st slot))
    (setq part (- part leading) total (- total leading))
    (canvas-minimap--blank-slot st slot)
    (let* ((data (canvas-minimap--state-data st))
           (thumb nil)
           (w (canvas-minimap--state-width st))
           (lh (canvas-minimap--state-lh st))
           (pad (canvas-minimap--state-scale st))
           (y0 (canvas-minimap--slot-y st slot))
           (tx0 (canvas-minimap--state-text-x0 st))
           (bg (canvas-minimap--state-bg st))
           (fg (canvas-minimap--state-fg st))
           (x1 (cdr (canvas-minimap--picture-x st img)))
           (fill (canvas-minimap--mix bg fg 0.16))
           (edge (canvas-minimap--mix bg fg 0.42))
           (tw (- x1 tx0))
           (th (* total lh)))
      (setq thumb (canvas-minimap--image-thumb img tw th (canvas-minimap--state-bgpix st)))
      (if thumb
          (let ((dy 0))
            (while (< dy lh)
              (let ((src (* (+ (* part lh) dy) tw))
                    (dst (+ (* (+ y0 dy) w) tx0))
                    (dx 0))
                (while (< dx tw)
                  (aset data (+ dst dx) (aref thumb (+ src dx)))
                  (setq dx (1+ dx))))
              (setq dy (1+ dy))))
        (canvas-minimap--fill-cell data w y0 lh tx0 x1 fill)
        ;; An outline, so a picture reads as one thing rather than as a
        ;; smudge that happens to be several rows tall.
        (canvas-minimap--fill-cell data w y0 lh tx0 (+ tx0 pad) edge)
        (canvas-minimap--fill-cell data w y0 lh (- x1 pad) x1 edge)
        (when (eq part 0)
          (canvas-minimap--fill-cell data w y0 pad tx0 x1 edge))
        (when (eq part (1- total))
          (canvas-minimap--fill-cell data w (- (+ y0 lh) pad) pad tx0 x1 edge))))))

(defun canvas-minimap--render-slice (st buf win start rows)
  "Draw buffer lines START.. of BUF into ST's ROWS slots.
Return non-nil if any slot was drawn."
  (let ((canvas-minimap--rendering t)
        ;; `get-char-property' resolves positions in the window's own
        ;; buffer, so a window showing anything else must not be used.
        (win (and (window-live-p win) (eq (window-buffer win) buf) win)))
    (with-current-buffer buf
      (save-excursion
        (save-restriction
          (widen)
          (let* ((cookies (canvas-minimap--state-cookies st))
                 (parts (canvas-minimap--state-parts st))
                 (slot-of (canvas-minimap--state-slot-of st))
                 (slot-pos (canvas-minimap--state-slot-pos st))
                 (deco (canvas-minimap--state-deco st))
                 (dirty canvas-minimap--dirty)
                 (slot 0)
                 (line start)
                 (past nil)
                 (painted nil))
            (clrhash slot-of)
            (goto-char (point-min))
            (forward-line (1- start))
            (while (and (not (eobp)) (not (canvas-minimap--line-visible-p)))
              (goto-char (next-single-char-property-change (point) 'invisible))
              (unless (bolp) (forward-line 1))
              (setq line (1+ (count-lines (point-min) (point)))))
            (set-marker (canvas-minimap--state-slice-beg st) (point) buf)
            (while (< slot rows)
              (if past
                  (progn
                    (unless (and (null (aref cookies slot))
                                 (eql (aref parts slot) 0))
                      (canvas-minimap--blank-slot st slot)
                      (aset cookies slot nil)
                      (aset parts slot 0)
                      (aset deco slot 0)
                      (setq painted t))
                    (aset slot-pos slot nil)
                    (setq slot (1+ slot)))
                ;; What the drawing asks for is what the line gets,
                ;; clipped by what is left of the canvas.
                (let* ((beg (point))
                       (eol (line-end-position))
                       (_ (canvas-minimap--fontify beg eol))
                       (img (canvas-minimap--line-image st beg eol win))
                       (want (if img (nth 1 img) 1))
                       (n (min want (- rows slot)))
                       (part 0))
                  (puthash line slot slot-of)
                  (while (< part n)
                    (let ((i (+ slot part)))
                      (aset slot-pos i beg)
                      (when (or (not (eql (aref cookies i) line))
                                (not (eql (aref parts i) part))
                                (and dirty
                                     (<= (car dirty) line)
                                     (<= line (cdr dirty))))
                        (canvas-minimap--render-part st i beg eol win part want
                                                    (car img) (nth 2 img))
                        (aset cookies i line)
                        (aset parts i part)
                        (aset deco i 0)
                        (setq painted t)))
                    (setq part (1+ part)))
                  (setq slot (+ slot n))
                  (let ((crossed (canvas-minimap--forward-visible-line)))
                    (if crossed
                        (setq line (+ line crossed))
                      (setq past t))))))
            (set-marker (canvas-minimap--state-slice-end st) (point) buf)
            painted))))))

(defun canvas-minimap--sync (win buf mmwin st)
  "Bring the minimap in MMWIN up to date for BUF as shown in WIN.
ST is what that minimap last drew; the state to keep is returned."
  (canvas-minimap--apply-width mmwin)
  (let* (;; One character cell short of the window's body.  With
         ;; `truncate-lines' on, the display keeps the last cell of a
         ;; line for the truncation glyph, and an image exactly as wide
         ;; as the body loses that much off its right edge -- silently,
         ;; since what it takes is only ever the last few columns of the
         ;; map.
         (w (max 8 (- (window-body-width mmwin t)
                      (frame-char-width (window-frame mmwin)))))
         (h (max 8 (window-body-height mmwin t)))
         (sc (canvas-minimap--device-scale))
         (bg (face-background 'default nil t))
         (fresh nil))
    (when (or (null st)
              (/= (* sc w) (canvas-minimap--state-width st))
              (/= (* sc h) (canvas-minimap--state-height st))
              (/= sc (canvas-minimap--state-scale st))
              (/= (canvas-minimap--ink-rows sc)
                  (canvas-minimap--state-ink-rows st))
              (/= (* sc (max 1 canvas-minimap-column-width))
                  (canvas-minimap--state-glyph-cw st))
              (/= (canvas-minimap--state-ph st)
                  (* sc (max 1 canvas-minimap-point-height)))
              (/= (canvas-minimap--state-top st)
                  (min (canvas-minimap--layout-height (* sc w) sc (window-frame win))
                       (max 0 (- (* sc h)
                                 (* 8 sc (max 1 canvas-minimap-line-height))))))
              (not (equal (canvas-minimap--font-family)
                          (canvas-minimap--state-glyph-font st)))
              (not (eq canvas-minimap-glyph-detail
                       (canvas-minimap--state-detail st)))
              (/= (canvas-minimap--state-gut-w st)
                  (max 0 (min (* sc (max 0 canvas-minimap-gutter-width))
                              (/ (* sc w) 2))))
              (not (equal (canvas-minimap--rgb bg)
                          (canvas-minimap--state-bg st))))
      (setq st (canvas-minimap--make-state w h (window-frame win))
            fresh t)
      (canvas-minimap--show-image mmwin (canvas-minimap--state-image st)))
    (unless (and (eq buf (canvas-minimap--state-buffer st))
                 (eq win (canvas-minimap--state-window st)))
      (setf (canvas-minimap--state-buffer st) buf
            (canvas-minimap--state-window st) win)
      (setq fresh t)
      (canvas-minimap--invalidate st))
    (let* ((rows (canvas-minimap--state-rows st))
           (total (with-current-buffer buf
                    (save-restriction
                      (widen)
                      (line-number-at-pos (point-max)))))
           (wstart (canvas-minimap--line-of buf (window-start win)))
           (wend (canvas-minimap--line-of
                  buf (canvas-minimap--window-end win buf)))
           (vis (max 1 (1+ (- wend wstart))))
           ;; The window's point, not the buffer's: while a minibuffer is
           ;; reading, the window is not the selected one and the two
           ;; have parted company -- and the window's is the one being
           ;; previewed.
           (ppos (window-point win))
           (pline (canvas-minimap--line-of buf ppos))
           ;; A line the buffer already highlights marks itself.
           (pmarked (and canvas-minimap-point-defer
                         (with-current-buffer buf
                           (let ((bg (canvas-minimap--face-attr
                                      (get-char-property
                                       (save-excursion
                                         (goto-char ppos)
                                         (line-beginning-position))
                                       'face win)
                                      :background)))
                             (and bg (not (equal (canvas-minimap--rgb bg)
                                                 (canvas-minimap--state-bg st))))))))
           (goal (with-current-buffer buf
                   (save-excursion
                     (save-restriction
                       (widen)
                       (canvas-minimap--slice-start win rows total wstart vis)))))
           ;; Where the slice is drawn is not where it is headed: a jump
           ;; is walked to over a few frames rather than cut to.
           (start (canvas-minimap--glide st goal fresh))
           (painted fresh))
      ;; Where the new first line already sits decides the scroll.  Derived
      ;; rather than subtracted, because with invisible text stepped over a
      ;; slot is not its start plus its index -- and this is exact whenever
      ;; the line is still on the map at all.
      (let ((delta (canvas-minimap--slot-of-line st start)))
        (cond ((null delta) (canvas-minimap--invalidate st))
              ((/= delta 0)
               (canvas-minimap--shift st delta)
               (setq painted t))))
      (setf (canvas-minimap--state-start st) start)
      ;; The scan works over the previously drawn slice, which is what we
      ;; want: anything the shift exposed is already invalid.
      (canvas-minimap--scan-overlays st buf win)
      ;; A decoration option changed under a map that is already up.  The
      ;; tables are built once, so they are built again here, and what
      ;; they painted comes off first: a restore puts back the pixels
      ;; that were saved, whichever colours drew over them.
      (unless (equal (canvas-minimap--deco-signature)
                     (canvas-minimap--state-deco-sig st))
        (canvas-minimap--undecorate-all st)
        (canvas-minimap--tint-tables st)
        (setq painted t))
      ;; Faces are re-resolved every pass; only the ink tables persist.
      (clrhash (canvas-minimap--state-spec-memo st))
      (clrhash (canvas-minimap--state-gutter-colors st))
      (when (canvas-minimap--render-slice st buf win start rows)
        (setq painted t))
      (with-current-buffer buf (setq canvas-minimap--dirty nil))
      (when (canvas-minimap--render-gutter
             st (canvas-minimap--fringe-marks st buf win rows))
        (setq painted t))
      (let ((vp (canvas-minimap--viewport-slots st wstart wend rows)))
        (when (canvas-minimap--decorate
               st (car vp) (cdr vp)
               (unless pmarked (canvas-minimap--slot-of-line st pline))
               (canvas-minimap--match-hits st buf rows))
          (setq painted t)))
      ;; The strip keeps a signature of what it drew, and replaces it
      ;; only when it draws again.
      (let ((plan (canvas-minimap--state-layout st)))
        (canvas-minimap--render-layout st)
        (unless (eq plan (canvas-minimap--state-layout st))
          (setq painted t)))
      ;; Handing the same pixels back costs a full upload of the image,
      ;; which is most of what an idle update costs on a remote display.
      (when painted
        (canvas-refresh (canvas-minimap--state-image st) 'reload-data))))
  st)

(defun canvas-minimap--reap ()
  "Forget minimaps whose window has gone, and kill what they were showing.
A window deleted by anything other than `canvas-minimap--destroy' --
`delete-window' on its parent, a frame closing -- leaves its buffer
behind with nothing to show it."
  (let (dead)
    (maphash (lambda (mmwin _st)
               (unless (window-live-p mmwin) (push mmwin dead)))
             canvas-minimap--states)
    (dolist (mmwin dead) (remhash mmwin canvas-minimap--states)))
  (dolist (b (buffer-list))
    (when (and (string-prefix-p " *canvas-minimap*" (buffer-name b))
               (not (get-buffer-window b t)))
      (kill-buffer b))))

(defun canvas-minimap--sync-window (mmwin target)
  "Bring MMWIN up to date for the window TARGET is showing."
  (when (and (window-live-p mmwin) (window-live-p target))
    (let ((buf (window-buffer target)))
      (when (canvas-minimap--eligible-p target buf)
        (puthash mmwin
                 (canvas-minimap--sync target buf mmwin
                                       (gethash mmwin canvas-minimap--states))
                 canvas-minimap--states)))))

(defun canvas-minimap--update-per-frame (frame)
  "Keep one minimap on FRAME, following its selected window.
While a minibuffer is reading, the window it was entered from is what
the minimap follows, so a completion that previews as it goes --
`consult-line' scrolling the buffer behind it -- is drawn while it
happens.  No window is made or destroyed then: a minibuffer is no place
for the layout to move under the reader."
  (let* ((mini (minibufferp (window-buffer (frame-selected-window frame))))
         (win (if (not mini)
                  (frame-selected-window frame)
                (let ((w (minibuffer-selected-window)))
                  (and (window-live-p w) (eq (window-frame w) frame) w)))))
    (cond
     ((null win) nil)                   ; a minibuffer with nothing behind it
     ((canvas-minimap--eligible-p win (window-buffer win))
      (let ((mm (canvas-minimap--frame-window frame)))
        (when (and mm (not mini) (canvas-minimap--stranded-p mm))
          (canvas-minimap--destroy mm)
          (setq mm nil))
        (when-let* ((mmwin (or mm (and (not mini)
                                       (canvas-minimap--make-window nil)))))
          (canvas-minimap--sync-window mmwin win))))
     (mini nil)                         ; keep showing the last buffer
     (t (canvas-minimap--hide frame)))))

(defun canvas-minimap--update-per-window (frame)
  "Keep a minimap beside every window on FRAME that has room for one."
  (dolist (mm (canvas-minimap--windows frame))
    (let ((target (window-parameter mm 'canvas-minimap)))
      (unless (and (window-live-p target)
                   (not (eq target 'frame))
                   (canvas-minimap--eligible-p target (window-buffer target))
                   (canvas-minimap--wide-enough-p target))
        (canvas-minimap--destroy mm))))
  (dolist (w (window-list frame 'no-mini))
    (when (and (not (canvas-minimap--minimap-window-p w))
               (not (canvas-minimap--window-for w))
               (canvas-minimap--eligible-p w (window-buffer w))
               (canvas-minimap--wide-enough-p w))
      (canvas-minimap--make-window w)))
  (dolist (mm (canvas-minimap--windows frame))
    (canvas-minimap--sync-window mm (window-parameter mm 'canvas-minimap))))

(defun canvas-minimap--update ()
  "Refresh the minimaps on the selected frame."
  (setq canvas-minimap--timer nil)
  (when canvas-minimap-mode
    (let ((frame (selected-frame)))
      (canvas-minimap--reap)
      ;; A placement change leaves the wrong kind of window standing.
      (dolist (mm (canvas-minimap--windows frame))
        (let ((target (window-parameter mm 'canvas-minimap)))
          (when (if (eq canvas-minimap-placement 'window)
                    (eq target 'frame)
                  (not (eq target 'frame)))
            (canvas-minimap--destroy mm))))
      (condition-case err
          (if (eq canvas-minimap-placement 'window)
              (canvas-minimap--update-per-window frame)
            (canvas-minimap--update-per-frame frame))
        (error
         (message "canvas-minimap: %s" (error-message-string err))
         (maphash (lambda (_ st) (canvas-minimap--invalidate st))
                  canvas-minimap--states))))))

(defvar canvas-minimap--poll-timer nil)

(defun canvas-minimap--poll ()
  "Notice highlighting that changed with no command to announce it."
  (when canvas-minimap-mode
    (let ((stale nil))
      (maphash
       (lambda (mmwin st)
         (let ((buf (canvas-minimap--state-buffer st))
               (win (canvas-minimap--state-window st)))
           (when (and (window-live-p mmwin)
                      (buffer-live-p buf)
                      (window-live-p win)
                      (eq buf (window-buffer win))
                      ;; A scan that fails leaves what it remembered
                      ;; half replaced, and a timer that fails on its own
                      ;; leftovers fails again every time it runs.
                      (condition-case err
                          (canvas-minimap--scan-overlays st buf win)
                        (error
                         (setf (canvas-minimap--state-overlays st)
                               (make-hash-table :test 'eq))
                         (message "canvas-minimap: %s" (error-message-string err))
                         nil)))
             (setq stale t))))
       canvas-minimap--states)
      (when stale (canvas-minimap--update)))))

(defun canvas-minimap--schedule (&rest _)
  "Ask for an update once Emacs goes idle."
  (when canvas-minimap-mode
    (when canvas-minimap--timer (cancel-timer canvas-minimap--timer))
    (setq canvas-minimap--timer
          (run-with-idle-timer canvas-minimap-update-delay nil
                               #'canvas-minimap--update))))

(defun canvas-minimap-refresh ()
  "Redraw every minimap from scratch."
  (interactive)
  (maphash (lambda (_ st) (canvas-minimap--invalidate st))
           canvas-minimap--states)
  (canvas-minimap--update))

;;;; Mouse

(defun canvas-minimap--goto-y (st y)
  "Scroll the source window to the buffer line the minimap draws at Y."
  (let* ((win (canvas-minimap--state-window st))
         ;; The click arrives in window pixels; the canvas may be finer.
         (slot (/ (max 0 (- (* y (canvas-minimap--state-scale st))
                            (canvas-minimap--state-top st)))
                  (canvas-minimap--state-lh st)))
         (cookies (canvas-minimap--state-cookies st))
         (line (or (and (< -1 slot (length cookies))
                        (let ((c (aref cookies slot))) (and (integerp c) c)))
                   (canvas-minimap--state-start st))))
    (when (window-live-p win)
      (with-selected-window win
        (goto-char (point-min))
        (forward-line (1- line))
        (recenter))
      (canvas-minimap--update))))

(defun canvas-minimap--state-at (event)
  "The state of the minimap EVENT happened in."
  (gethash (posn-window (event-start event)) canvas-minimap--states))

(defun canvas-minimap-mouse-drag (event)
  "Scrub the source window with the mouse, starting from EVENT.
A click on the layout strip goes to the window it lands on instead: the
strip is a plan of the frame, so pointing at a pane is the obvious way
to ask for it."
  (interactive "e")
  (let* ((st (canvas-minimap--state-at event))
         (xy (and st (posn-object-x-y (event-start event))))
         (sc (and st (canvas-minimap--state-scale st)))
         (canvas-minimap--dragging t))
    (when xy
      (if-let* ((jump (canvas-minimap--layout-window-at
                       st (* sc (car xy)) (* sc (cdr xy)))))
          (select-window jump)
        (canvas-minimap--scrub st xy)
        (track-mouse
          (let (ev)
            (while (progn (setq ev (read-event))
                          (mouse-movement-p ev))
              (let ((posn (event-start ev)))
                (when (canvas-minimap--minimap-window-p (posn-window posn))
                  (when-let* ((xy (posn-object-x-y posn)))
                    (canvas-minimap--scrub st xy)))))
            (when ev (push ev unread-command-events))))))))

(defun canvas-minimap--scroll (event lines)
  "Scroll the window EVENT's minimap belongs to by LINES."
  (when-let* ((st (canvas-minimap--state-at event))
              (win (canvas-minimap--state-window st)))
    (when (window-live-p win)
      (with-selected-window win
        (condition-case nil (scroll-up lines) (error nil)))
      (canvas-minimap--update))))

(defun canvas-minimap-scroll-up (event)
  "Scroll the source window of the minimap EVENT is over down a few lines."
  (interactive "e")
  (canvas-minimap--scroll event 3))

(defun canvas-minimap-scroll-down (event)
  "Scroll the source window of the minimap EVENT is over up a few lines."
  (interactive "e")
  (canvas-minimap--scroll event -3))

(defvar canvas-minimap-image-map
  (let ((map (make-sparse-keymap)))
    (define-key map [down-mouse-1] #'canvas-minimap-mouse-drag)
    (define-key map [mouse-1] #'ignore)
    (define-key map [drag-mouse-1] #'ignore)
    (define-key map [wheel-down] #'canvas-minimap-scroll-up)
    (define-key map [wheel-up] #'canvas-minimap-scroll-down)
    (define-key map [mouse-5] #'canvas-minimap-scroll-up)
    (define-key map [mouse-4] #'canvas-minimap-scroll-down)
    (define-key map [C-wheel-down] #'canvas-minimap-narrow)
    (define-key map [C-wheel-up] #'canvas-minimap-widen)
    (define-key map [C-mouse-5] #'canvas-minimap-narrow)
    (define-key map [C-mouse-4] #'canvas-minimap-widen)
    (define-key map [mouse-3] #'canvas-minimap-menu)
    map)
  "Keymap active over the minimap image.")

;;;; Menu

(eval-and-compile
  (defconst canvas-minimap--menu
    '((("Window"
        ("ww" "Width" canvas-minimap-width)
        ("wS" "Width step" canvas-minimap-width-step)
        ("ws" "Side" canvas-minimap-side)
        ("wp" "Placement" canvas-minimap-placement)
        ("wm" "Least window width" canvas-minimap-min-window-width
         :needs (canvas-minimap-placement window))
        ("wd" "Device scale" canvas-minimap-device-scale)
        ("fw" "Fringe strip width" canvas-minimap-gutter-width)
        ("fs" "Fringe strip side" canvas-minimap-gutter-side
         :needs (canvas-minimap-gutter-width . cl-plusp)))
       ("Lines"
        ("lh" "Line height" canvas-minimap-line-height)
        ("lg" "Line gap" canvas-minimap-line-gap)
        ("lc" "Column width" canvas-minimap-column-width)
        ("li" "Ink" canvas-minimap-ink)
        ("ld" "Glyph detail" canvas-minimap-glyph-detail)
        ("la" "Glyph tables for other fonts" canvas-minimap-glyph-auto-generate)
        ("lD" "Glyph directory" canvas-minimap-glyph-directory
         :needs (canvas-minimap-glyph-auto-generate t))
        ("lt" "Image thumbnails" canvas-minimap-image-thumbnails))
       ("Viewport"
        ("vs" "Style" canvas-minimap-viewport-style)
        ("vc" "Colour" canvas-minimap-viewport-color
         :needs (canvas-minimap-viewport-style tint both))
        ("va" "Alpha" canvas-minimap-viewport-alpha
         :needs (canvas-minimap-viewport-style tint both))
        ("vo" "Outline colour" canvas-minimap-viewport-outline-color
         :needs (canvas-minimap-viewport-style outline both)))
       ("Point"
        ("pp" "Show" canvas-minimap-show-point)
        ("pc" "Colour" canvas-minimap-point-color :needs (canvas-minimap-show-point t))
        ("ph" "Height" canvas-minimap-point-height :needs (canvas-minimap-show-point t))
        ("pd" "Defer to highlighting" canvas-minimap-point-defer
         :needs (canvas-minimap-show-point t))))
      (("Window plan"
        ("sh" "Height" canvas-minimap-layout-height)
        ("s1" "Even with one window" canvas-minimap-layout-always
         :needs (canvas-minimap-layout-height . identity))
        ("sl" "Labels" canvas-minimap-layout-labels
         :needs (canvas-minimap-layout-height . identity))
        ("sc" "Colour" canvas-minimap-layout-color
         :needs (canvas-minimap-layout-height . identity))
        ("sa" "Alpha" canvas-minimap-layout-alpha
         :needs (canvas-minimap-layout-height . identity))
        ("so" "Outline colour" canvas-minimap-layout-outline-color
         :needs (canvas-minimap-layout-height . identity))
        ("sb" "Background" canvas-minimap-layout-background
         :needs (canvas-minimap-layout-height . identity)))
       ("Glide"
        ("gg" "Glide" canvas-minimap-smooth-scroll)
        ("gi" "Frame interval" canvas-minimap-smooth-scroll-interval
         :needs (canvas-minimap-smooth-scroll t))
        ("gf" "Fraction per frame" canvas-minimap-smooth-scroll-step
         :needs (canvas-minimap-smooth-scroll t))
        ("gt" "Shortest glide" canvas-minimap-smooth-scroll-threshold
         :needs (canvas-minimap-smooth-scroll t))
        ("gd" "Longest glide" canvas-minimap-smooth-scroll-distance
         :needs (canvas-minimap-smooth-scroll t)))
       ("Matches"
        ("mm" "Mark matches" canvas-minimap-highlight-matches)
        ("mc" "Colour" canvas-minimap-match-color
         :needs (canvas-minimap-highlight-matches t))
        ("ma" "Alpha" canvas-minimap-match-alpha
         :needs (canvas-minimap-highlight-matches t))
        ("ml" "Most marked" canvas-minimap-match-limit
         :needs (canvas-minimap-highlight-matches t)))
       ("Running"
        ("M" "Minimap" canvas-minimap-mode :set-value #'canvas-minimap--set-mode)
        ("x" "Excluded modes" canvas-minimap-exclude-modes)
        ("tp" "Poll interval" canvas-minimap-poll-interval)
        ("tu" "Update delay" canvas-minimap-update-delay))))
    "What `canvas-minimap-menu' offers: rows of columns of options.
An option is (KEY LABEL VARIABLE . PLIST), PLIST going to its command.
A `:needs' of (VARIABLE . VALUES) or (VARIABLE . PREDICATE) in it says
what another option has to be for this one to have any effect; while it
is not, the option is shown dimmed, with that as the reason.")

  (defun canvas-minimap--menu-key (option)
    "The key `canvas-minimap-menu' gives OPTION."
    (or (cl-loop for row in canvas-minimap--menu
                 thereis (cl-loop for column in row
                                  thereis (car (cl-find option (cdr column)
                                                        :key #'caddr))))
        (error "%s is not in the menu" option)))

  (defun canvas-minimap--menu-command (option)
    "Name of the menu command that sets OPTION."
    (intern (format "canvas-minimap-menu:%s"
                    (substring (symbol-name option) (length "canvas-minimap-"))))))

(defclass canvas-minimap--option (transient-lisp-variable)
  ((needs :initarg :needs :initform nil))
  "An option in the menu.
It is read the way its `defcustom' type says, shown by the name that
type gives its value, and applied the moment it is set, so the map shows
the change while the menu is still up.  NEEDS is what another option
has to be for this one to count, as `canvas-minimap--menu' spells it.")

(defun canvas-minimap--gate-open-p (gate)
  "Non-nil if GATE, a `:needs' of `canvas-minimap--menu', is satisfied."
  (let ((value (symbol-value (car gate)))
        (test (cdr gate)))
    (if (functionp test) (funcall test value) (memq value test))))

(defun canvas-minimap--short-value (value)
  "VALUE in a word, for a reason: on, off, or what it is."
  (cond ((eq value t) "on")
        ((null value) "off")
        (t (format "%s" value))))

(defun canvas-minimap--gate-reason (gate)
  "Why GATE is shut, naming the key that opens it."
  (format "(%s is %s)" (canvas-minimap--menu-key (car gate))
          (canvas-minimap--short-value (symbol-value (car gate)))))

(defun canvas-minimap--set-mode (_option value)
  "Turn the mode on or off, as VALUE says, through the mode function.
Setting the variable would leave a map up or missing."
  (canvas-minimap-mode (if value 1 -1)))

(defun canvas-minimap--option-type (obj)
  "The `defcustom' type of the option OBJ stands for."
  (get (oref obj variable) 'custom-type))

(defun canvas-minimap--type-consts (type)
  "The (VALUE . NAME) pairs a choice TYPE spells out."
  (cl-loop for alt in (cdr-safe type)
           when (eq (car-safe alt) 'const)
           collect (let ((value (car (last alt))))
                     (cons value (or (plist-get (cdr alt) :tag)
                                     (format "%s" value))))))

(defun canvas-minimap--type-allows-p (type kind)
  "Non-nil if TYPE is KIND, or a choice that admits it."
  (or (eq type kind)
      (and (eq (car-safe type) 'choice) (memq kind (cdr type)))))

(defun canvas-minimap--option-name (obj value)
  "VALUE as the menu shows it for OBJ: by the name its type gives it."
  (let* ((type (canvas-minimap--option-type obj))
         (named (assoc value (canvas-minimap--type-consts type))))
    (cond (named (cdr named))
          ((eq type 'boolean) (if value "on" "off"))
          ((stringp value) value)
          (t (prin1-to-string value)))))

(defun canvas-minimap--choice-value (input type value)
  "The value INPUT names among TYPE's choices; VALUE if it names nothing."
  (let ((consts (canvas-minimap--type-consts type)))
    (cond ((rassoc input consts) (car (rassoc input consts)))
          ((string-empty-p input) (if (assoc nil consts) nil value))
          ((and (canvas-minimap--type-allows-p type 'color)
                (color-defined-p input))
           input)
          ((and (or (canvas-minimap--type-allows-p type 'number)
                    (canvas-minimap--type-allows-p type 'integer))
                (string-match-p "\\`-?[0-9]+\\.?[0-9]*\\'" input))
           (string-to-number input))
          (t (user-error "%s is not one of the choices" input)))))

(defun canvas-minimap--read-choice (prompt type value)
  "Ask, with PROMPT, for one of TYPE's choices; VALUE is what it is now.
A colour or a number can be typed where TYPE admits one."
  (let ((names (append (mapcar #'cdr (canvas-minimap--type-consts type))
                       (and (canvas-minimap--type-allows-p type 'color)
                            (defined-colors)))))
    (canvas-minimap--choice-value (completing-read prompt names) type value)))

(defun canvas-minimap--enum-p (type)
  "Non-nil if TYPE is a choice among named values and nothing else."
  (and (eq (car-safe type) 'choice)
       (cl-every (lambda (alt) (eq (car-safe alt) 'const)) (cdr type))))

(defun canvas-minimap--next-const (type value)
  "The named value of TYPE after VALUE, round to the first after the last."
  (let ((values (mapcar #'car (canvas-minimap--type-consts type))))
    (or (cadr (memq value values)) (car values))))

(defun canvas-minimap--number-input (input type)
  "The number INPUT spells, if it spells one TYPE takes; else `none'."
  (if (string-match-p "\\`-?[0-9]+\\(\\.[0-9]*\\)?\\'" input)
      (let ((n (string-to-number input)))
        (if (and (eq type 'integer) (not (integerp n))) 'none n))
    'none))

(defun canvas-minimap--input-value (input type value)
  "What INPUT, typed at a prompt for an option of TYPE, means so far.
VALUE is the option's value now.  While INPUT means nothing yet, `none'."
  (condition-case nil
      (pcase type
        ((or 'integer 'float 'number) (canvas-minimap--number-input input type))
        ('directory (if (file-directory-p input) input 'none))
        (`(choice . ,_) (canvas-minimap--choice-value input type value))
        (_ (car (read-from-string input))))
    (error 'none)))

(declare-function vertico--candidate "ext:vertico")

(defun canvas-minimap--prompt-candidate ()
  "What the prompt is pointing at.
The completion in front of the cursor where a completion UI keeps one --
vertico or icomplete -- and what has been typed otherwise, so that
stepping through the candidates previews each in turn."
  (substring-no-properties
   (or (and (bound-and-true-p vertico--input) (fboundp 'vertico--candidate)
            (vertico--candidate))
       (and (bound-and-true-p icomplete-mode) minibuffer-completion-table
            (car-safe (completion-all-sorted-completions)))
       (minibuffer-contents-no-properties))))

(defun canvas-minimap--preview (obj was)
  "Draw the map with what the prompt points at for OBJ, once it is a value.
WAS is what OBJ had before the prompt, which an emptied prompt means."
  (let ((typed (canvas-minimap--input-value (canvas-minimap--prompt-candidate)
                                            (canvas-minimap--option-type obj) was)))
    (unless (or (eq typed 'none)
                (equal typed (symbol-value (oref obj variable))))
      (funcall (oref obj set-value) (oref obj variable) typed)
      ;; A value typed halfway can be one the map cannot be drawn with;
      ;; the next keystroke mends it, and nothing need be said meanwhile.
      (let ((inhibit-message t))
        (ignore-errors (canvas-minimap-refresh))))))

(defun canvas-minimap--read-previewing (obj reader)
  "Call READER for OBJ, drawing what is typed at its prompt as it is typed.
A quit at the prompt answers with what the option was, so the map is
drawn with that again by the ordinary route.  Letting the quit through
instead leaves transient with its menu hidden, as it is for the prompt,
and it does not bring it back."
  (let* ((was (symbol-value (oref obj variable)))
         (preview (lambda () (canvas-minimap--preview obj was))))
    (condition-case nil
        (minibuffer-with-setup-hook
            ;; Late in the hook, after a completion UI has moved its cursor.
            (lambda () (add-hook 'post-command-hook preview 90 t))
          (funcall reader))
      (quit was))))

(defun canvas-minimap--read-at-prompt (obj type value)
  "Ask for OBJ's value the way TYPE says; VALUE is what it is now."
  (let ((prompt (format "%s: " (oref obj description))))
    (pcase type
      ((or 'integer 'float 'number) (read-number prompt value))
      ('directory (read-directory-name prompt value))
      (`(choice . ,_) (canvas-minimap--read-choice prompt type value))
      (_ (read-from-minibuffer prompt (prin1-to-string value) nil t)))))

(cl-defmethod transient-infix-read ((obj canvas-minimap--option))
  "The next value for OBJ.
A switch flips, a choice among names moves on to the next, and anything
else is asked for at a prompt that draws what is typed as it is typed."
  (let ((type (canvas-minimap--option-type obj))
        (value (symbol-value (oref obj variable))))
    (cond ((eq type 'boolean) (not value))
          ((canvas-minimap--enum-p type) (canvas-minimap--next-const type value))
          (t (canvas-minimap--read-previewing
              obj (lambda () (canvas-minimap--read-at-prompt obj type value)))))))

(cl-defmethod transient-infix-set ((obj canvas-minimap--option) value)
  "Give OBJ's option VALUE, and redraw the maps with it."
  (cl-call-next-method obj value)
  (canvas-minimap-refresh))

(defconst canvas-minimap--menu-value-width 28
  "Columns a value may take in the menu before it is cut short.")

(cl-defmethod transient-format-value ((obj canvas-minimap--option))
  "OBJ's value, by name where its type has one for it, cut to fit.
The whole of it is there to edit when the option is picked.  An option
that is shut off by another says which, and how that one stands."
  (let ((gate (oref obj needs))
        (shut (oref obj inapt)))
    (concat (propertize (truncate-string-to-width
                         (canvas-minimap--option-name
                          obj (symbol-value (oref obj variable)))
                         canvas-minimap--menu-value-width nil nil t)
                        'face (if shut 'transient-inapt-suffix 'transient-value))
            (and shut
                 (propertize (concat "  " (canvas-minimap--gate-reason gate))
                             'face 'transient-inapt-suffix)))))

(eval-and-compile
  (defun canvas-minimap--menu-plist (plist)
    "PLIST of a menu option as its command's arguments.
A `:needs' is data, so it is quoted, and it brings an `:inapt-if' that
dims the option while the gate is shut."
    (cl-loop for (key value) on plist by #'cddr
             append (if (eq key :needs)
                        `(:needs ',value
                          :inapt-if (lambda () (not (canvas-minimap--gate-open-p ',value))))
                      (list key value)))))

(defmacro canvas-minimap--define-menu ()
  "Define a command for every option in `canvas-minimap--menu', and the menu.
The menu lays the options out as the table does: a row of columns for
each of its rows, the commands under their headings."
  (let ((items (cl-loop for row in canvas-minimap--menu
                        append (cl-loop for column in row append (cdr column)))))
    `(progn
       ,@(cl-loop for (key label option . plist) in items
                  collect `(transient-define-infix ,(canvas-minimap--menu-command option) ()
                             ,(format "Set `%s' from the menu." option)
                             :class 'canvas-minimap--option :variable ',option
                             :key ,key :description ,label
                             ,@(canvas-minimap--menu-plist plist)))
       (transient-define-prefix canvas-minimap-menu ()
         "Change how the minimap is drawn, and watch it change.
Every option of the package is here.  A switch flips and a choice among
names moves on with each press; anything else is asked for at a prompt,
and the map is drawn with what is typed as it is typed -- or with the
completion the cursor is on, under vertico or icomplete -- so a value
can be seen before it is entered, and C-g puts it back.  A change lasts the
session; `customize-group' is the way to keep one.  An option that
another one has switched off is dimmed, and says which."
         ;; So that what a switch dims and undims is redrawn as such.
         :refresh-suffixes t
         ,@(cl-loop for row in canvas-minimap--menu
                    collect (vconcat
                             (cl-loop for column in row
                                      collect (vconcat
                                               (list (car column))
                                               (cl-loop for item in (cdr column)
                                                        collect (list (canvas-minimap--menu-command
                                                                       (nth 2 item))))))))
         [("R" "Redraw" canvas-minimap-refresh :transient t)
          ("C" "Customize" (lambda () (interactive) (customize-group 'canvas-minimap)))
          ("q" "Quit" transient-quit-one)]))))

;;;###autoload (autoload 'canvas-minimap-menu "canvas-minimap" nil t)
(canvas-minimap--define-menu)

;;;; Mode

;;;###autoload
(define-minor-mode canvas-minimap-mode
  "Show a pixel minimap of the current buffer in a side window."
  :global t
  :lighter " Minimap"
  (if canvas-minimap-mode
      (if (not (and (display-graphic-p) (image-type-available-p 'canvas)))
          (progn
            (setq canvas-minimap-mode nil)
            (message "canvas-minimap: no canvas image support here"))
        (add-hook 'post-command-hook #'canvas-minimap--schedule)
        (add-hook 'window-configuration-change-hook #'canvas-minimap--schedule)
        (add-hook 'window-size-change-functions #'canvas-minimap--schedule)
        (add-hook 'window-selection-change-functions #'canvas-minimap--schedule)
        (add-hook 'before-change-functions #'canvas-minimap--before-change)
        (add-hook 'after-change-functions #'canvas-minimap--after-change)
        (when canvas-minimap-poll-interval
          (setq canvas-minimap--poll-timer
                (run-with-timer canvas-minimap-poll-interval
                                canvas-minimap-poll-interval
                                #'canvas-minimap--poll)))
        (canvas-minimap--schedule))
    (remove-hook 'post-command-hook #'canvas-minimap--schedule)
    (remove-hook 'window-configuration-change-hook #'canvas-minimap--schedule)
    (remove-hook 'window-size-change-functions #'canvas-minimap--schedule)
    (remove-hook 'window-selection-change-functions #'canvas-minimap--schedule)
    (remove-hook 'before-change-functions #'canvas-minimap--before-change)
    (remove-hook 'after-change-functions #'canvas-minimap--after-change)
    (when canvas-minimap--timer
      (cancel-timer canvas-minimap--timer)
      (setq canvas-minimap--timer nil))
    (when canvas-minimap--poll-timer
      (cancel-timer canvas-minimap--poll-timer)
      (setq canvas-minimap--poll-timer nil))
    (when canvas-minimap--glide-timer
      (cancel-timer canvas-minimap--glide-timer)
      (setq canvas-minimap--glide-timer nil))
    (dolist (frame (frame-list)) (canvas-minimap--hide frame))
    (clrhash canvas-minimap--states)))

(provide 'canvas-minimap)
;;; canvas-minimap.el ends here
