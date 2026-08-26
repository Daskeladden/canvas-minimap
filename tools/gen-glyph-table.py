#!/usr/bin/env python3
"""Rasterize a monospace font into canvas-minimap's glyph coverage table.

The minimap draws each character into a cell a couple of pixels across.  At
that size the font engine is itself just area-averaging outlines, so the way
to match it is to do the same thing once, offline, at high resolution, and
ship the result: a coverage grid per character that the package downsamples
to whatever cell size it is drawing at.

Usage: gen-glyph-table.py FONT.ttf > glyph-table.txt
"""
import sys
from PIL import Image, ImageDraw, ImageFont

GW, GH = 8, 24          # master grid per character
FIRST, LAST = 32, 126   # printable ASCII
SIZE = 96               # rasterize this big, then average down


def main(path):
    font = ImageFont.truetype(path, SIZE)
    ascent, descent = font.getmetrics()
    adv = max(1, round(font.getlength("M")))
    cell = (adv, ascent + descent)

    rows = []
    for code in range(FIRST, LAST + 1):
        img = Image.new("L", cell, 0)
        ImageDraw.Draw(img).text((0, 0), chr(code), font=font, fill=255)
        # BOX is a true area average, which is what downsampling coverage wants.
        small = img.resize((GW, GH), Image.Resampling.BOX)
        rows.append("".join("%x" % round(v / 255 * 15) for v in small.getdata()))

    sys.stderr.write("font=%s advance=%d ascent=%d descent=%d cell=%s\n"
                     % (path, adv, ascent, descent, cell))
    print("".join(rows))


if __name__ == "__main__":
    main(sys.argv[1])
