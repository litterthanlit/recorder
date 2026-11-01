#!/usr/bin/env python3
"""Draws the app icon and writes it into Assets.xcassets/AppIcon.appiconset.

    python3 scripts/make-icon.py

Pure Python (zlib and struct), so it runs anywhere without image libraries. The icon is
drawn once at 1024 px with analytic anti-aliasing and scaled down for the smaller sizes.

The design: the macOS rounded-square body in the black of the components system's
bumper, a smoked-glass window, and Trace's mark on it: the four corners of a viewfinder,
the top-right one red (REC). The corners' proportions are `FrameMark.icon` in
Recorder/Models/FrameMark.swift, which the brand mark and the menu bar item draw from.
"""

import json
import math
import struct
import zlib
from pathlib import Path

SIZE = 1024
ICONSET = Path(__file__).resolve().parent.parent / "Recorder" / "Assets.xcassets" / "AppIcon.appiconset"

# Body: Apple's macOS icon grid (824 px square, 100 px margin, ~185 px corner radius).
BODY_MIN, BODY_MAX, BODY_RADIUS = 100.0, 924.0, 185.0
BODY = (0x0D, 0x0D, 0x0E)  # device-rim

# The window: smoked glass lit from the top (device-window), 60 px in from the body.
WINDOW_MIN, WINDOW_MAX, WINDOW_RADIUS = 160.0, 864.0, 130.0
WINDOW_STOPS = ((0.0, (0x2A, 0x2A, 0x2B)), (0.7, (0x14, 0x14, 0x15)), (1.0, (0x0E, 0x0E, 0x0F)))

# The corners (FrameMark.icon at 824 px, offset by the body's 100 px margin).
CORNER_NEAR, CORNER_FAR = 303.0, 721.0
CORNER_ARM = 124.0
CORNER_WIDTH = 66.0
CORNER_INK = (0xF5, 0xF5, 0xF5)
REC = (0xFF, 0x5C, 0x62)  # device-rec, dark theme


def corner_lines():
    """Each corner's two strokes as segments, with its colour; the top-right one is REC."""
    n, f, a = CORNER_NEAR, CORNER_FAR, CORNER_ARM
    corners = [
        (((n, n + a), (n, n), (n + a, n)), CORNER_INK),
        (((f - a, n), (f, n), (f, n + a)), REC),
        (((f, f - a), (f, f), (f - a, f)), CORNER_INK),
        (((n + a, f), (n, f), (n, f - a)), CORNER_INK),
    ]
    return [((points[0], points[1]), (points[1], points[2]), color) for points, color in corners]


CORNERS = corner_lines()


def clamp(value, low=0.0, high=1.0):
    return low if value < low else high if value > high else value


def coverage(distance):
    """Signed distance (negative inside) to pixel coverage, about one pixel of edge."""
    return clamp(0.5 - distance)


def rounded_rect_distance(x, y, low=BODY_MIN, high=BODY_MAX, radius=BODY_RADIUS):
    center = (low + high) / 2
    half = (high - low) / 2 - radius
    dx = abs(x - center) - half
    dy = abs(y - center) - half
    outside = math.hypot(max(dx, 0.0), max(dy, 0.0))
    inside = min(max(dx, dy), 0.0)
    return outside + inside - radius


def segment_distance(px, py, a, b):
    ax, ay = a
    bx, by = b
    vx, vy = bx - ax, by - ay
    t = clamp(((px - ax) * vx + (py - ay) * vy) / (vx * vx + vy * vy))
    return math.hypot(px - ax - vx * t, py - ay - vy * t)


def window_color(px, py):
    """Radial gradient from the top centre of the window, like the components system's
    device-window."""
    t = clamp(math.hypot(px - 512, py - WINDOW_MIN) / (1.1 * (WINDOW_MAX - WINDOW_MIN)))
    for (t0, c0), (t1, c1) in zip(WINDOW_STOPS, WINDOW_STOPS[1:]):
        if t <= t1:
            k = (t - t0) / (t1 - t0)
            return tuple(c0[i] + (c1[i] - c0[i]) * k for i in range(3))
    return WINDOW_STOPS[-1][1]


def over(dst, color, alpha):
    """Source-over of a straight-alpha colour onto a straight-alpha pixel."""
    if alpha <= 0:
        return dst
    r, g, b, a = dst
    out_a = alpha + a * (1 - alpha)
    if out_a <= 0:
        return (0.0, 0.0, 0.0, 0.0)
    mix = lambda s, d: (s * alpha + d * a * (1 - alpha)) / out_a
    return (mix(color[0], r), mix(color[1], g), mix(color[2], b), out_a)


def shade(x, y):
    px, py = x + 0.5, y + 0.5
    pixel = (0.0, 0.0, 0.0, 0.0)

    # Soft shadow under the body.
    shadow_distance = rounded_rect_distance(px, py - 16)
    shadow = 0.26 * clamp(1 - (shadow_distance + 6) / 36) if shadow_distance < 30 else 0.0
    pixel = over(pixel, (0, 0, 0), shadow)

    body_distance = rounded_rect_distance(px, py)
    body = coverage(body_distance)
    if body <= 0:
        return pixel
    # A lit top edge, as on everything raised in the components system.
    rim = clamp(1 - abs(body_distance + 3) / 3) * clamp((300 - py) / 200) * 0.22
    color = tuple(c + (255 - c) * rim for c in BODY)
    pixel = over(pixel, color, body)

    window = coverage(rounded_rect_distance(px, py, WINDOW_MIN, WINDOW_MAX, WINDOW_RADIUS))
    if window <= 0:
        return pixel
    pixel = over(pixel, window_color(px, py), window)

    half = CORNER_WIDTH / 2
    for first, second, color in CORNERS:
        distance = min(segment_distance(px, py, *first), segment_distance(px, py, *second)) - half
        if distance < 1:
            pixel = over(pixel, color, coverage(distance))
    return pixel


def render():
    rows = []
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            r, g, b, a = shade(x, y)
            row.append((r, g, b, a))
        rows.append(row)
    return rows


def downsample(rows, size):
    """Area average (premultiplied) from SIZE to `size`."""
    factor = SIZE / size
    result = []
    for y in range(size):
        y0, y1 = int(y * factor), max(int((y + 1) * factor), int(y * factor) + 1)
        out_row = []
        for x in range(size):
            x0, x1 = int(x * factor), max(int((x + 1) * factor), int(x * factor) + 1)
            total_r = total_g = total_b = total_a = 0.0
            count = 0
            for yy in range(y0, y1):
                src = rows[yy]
                for xx in range(x0, x1):
                    r, g, b, a = src[xx]
                    total_r += r * a
                    total_g += g * a
                    total_b += b * a
                    total_a += a
                    count += 1
            a = total_a / count
            if a > 0:
                out_row.append((total_r / total_a, total_g / total_a, total_b / total_a, a))
            else:
                out_row.append((0.0, 0.0, 0.0, 0.0))
        result.append(out_row)
    return result


def write_png(rows, path):
    height = len(rows)
    width = len(rows[0])
    raw = bytearray()
    for row in rows:
        raw.append(0)
        for r, g, b, a in row:
            raw.extend((
                int(round(clamp(r, 0, 255))),
                int(round(clamp(g, 0, 255))),
                int(round(clamp(b, 0, 255))),
                int(round(clamp(a) * 255)),
            ))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    path.write_bytes(png)


def main():
    full = render()
    entries = []
    rendered = {SIZE: full}
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            if pixels not in rendered:
                rendered[pixels] = downsample(full, pixels)
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            write_png(rendered[pixels], ICONSET / name)
            entries.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
            print(f"wrote {name} ({pixels} px)")
    contents = {"images": entries, "info": {"author": "xcode", "version": 1}}
    (ICONSET / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


if __name__ == "__main__":
    main()
