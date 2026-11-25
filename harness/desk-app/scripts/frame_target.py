#!/usr/bin/env python3
"""A window frame for the smoke to set: inside the screen's visible frame, at
least the window's smallest frame, and not the frame it has now. Prints
"X Y W H" (whole points, from the bottom left as AppKit counts), or "none"
when the screen leaves no room for another one.

usage: frame_target.py "VX VY VW VH" "MIN_W MIN_H" "X Y W H"
"""
import math
import sys


def target(visible, minimum, current):
    vx, vy, vw, vh = visible
    mw, mh = (math.ceil(v) for v in minimum)
    # whole points only, inside the visible frame
    lo_x, lo_y = math.ceil(vx), math.ceil(vy)
    hi_x, hi_y = math.floor(vx + vw), math.floor(vy + vh)
    room_w, room_h = hi_x - lo_x, hi_y - lo_y
    if room_w < mw or room_h < mh:
        return None
    now = tuple(round(v) for v in current)
    # halfway between the smallest frame and the screen, in the middle; then
    # the smallest frame in each corner
    tw, th = mw + (room_w - mw) // 2, mh + (room_h - mh) // 2
    candidates = [(lo_x + (room_w - tw) // 2, lo_y + (room_h - th) // 2, tw, th)]
    for x, y in ((lo_x, lo_y), (hi_x - mw, hi_y - mh), (lo_x, hi_y - mh), (hi_x - mw, lo_y)):
        candidates.append((x, y, mw, mh))
    for c in candidates:
        if c != now:
            return c
    return None


def numbers(text, n):
    v = [float(x) for x in text.split()]
    if len(v) != n:
        raise ValueError(f"{n} numbers expected: {text!r}")
    return v


def main():
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    t = target(numbers(sys.argv[1], 4), numbers(sys.argv[2], 2), numbers(sys.argv[3], 4))
    print("none" if t is None else " ".join(str(v) for v in t))
    return 0


if __name__ == "__main__":
    sys.exit(main())
