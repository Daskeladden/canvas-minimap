#!/usr/bin/env python3
"""Downsample an image for canvas-minimap.

Usage: gen-image-thumb.py FILE WIDTH HEIGHT [BACKGROUND]

Writes WIDTH*HEIGHT pixels as one line of hex RRGGBB per row.  BACKGROUND
is a hex RRGGBB the image is composited onto, so a transparent PNG comes
out over the minimap's own background rather than over black.
"""

import sys

from PIL import Image


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    path, width, height = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    back = sys.argv[4] if len(sys.argv) > 4 else "000000"
    if width < 1 or height < 1:
        sys.exit("size must be positive")

    im = Image.open(path)
    im.seek(0) if getattr(im, "is_animated", False) else None
    im = im.convert("RGBA")
    flat = Image.new("RGBA", im.size, (int(back[0:2], 16),
                                       int(back[2:4], 16),
                                       int(back[4:6], 16), 255))
    flat.alpha_composite(im)
    # BOX averages over the whole source area, which is what you want when
    # a photograph has to become sixty pixels tall.
    small = flat.convert("RGB").resize((width, height), Image.BOX)

    rows = []
    for y in range(height):
        rows.append("".join("%02x%02x%02x" % small.getpixel((x, y))
                            for x in range(width)))
    sys.stdout.write("\n".join(rows))


if __name__ == "__main__":
    main()
