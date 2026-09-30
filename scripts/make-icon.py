#!/usr/bin/env python3
"""Draws the app icon and writes it into Assets.xcassets/AppIcon.appiconset.

    python3 scripts/make-icon.py

Pure Python (zlib and struct), so it runs anywhere without image libraries. The icon is
drawn once at 1024 px with analytic anti-aliasing and scaled down for the smaller sizes.

The design: the macOS rounded-square body in the brand violet, with a dotted cursor
trail curving up to a click, and the click's ripple rings, which is what Trace turns a
recording into.
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
TOP_LEFT = (0x9B, 0x8A, 0xFA)
BOTTOM_RIGHT = (0x4B, 0x2F, 0xC2)

CLICK = (616.0, 408.0)
TRAIL_START = (318.0, 752.0)
TRAIL_CONTROL_1 = (300.0, 560.0)
TRAIL_CONTROL_2 = (420.0, 470.0)


def clamp(value, low=0.0, high=1.0):
    return low if value < low else high if value > high else value


def coverage(distance):
    """Signed distance (negative inside) to pixel coverage, about one pixel of edge."""
    return clamp(0.5 - distance)


def rounded_rect_distance(x, y):
    center = (BODY_MIN + BODY_MAX) / 2
    half = (BODY_MAX - BODY_MIN) / 2 - BODY_RADIUS
    dx = abs(x - center) - half
    dy = abs(y - center) - half
    outside = math.hypot(max(dx, 0.0), max(dy, 0.0))
    inside = min(max(dx, dy), 0.0)
    return outside + inside - BODY_RADIUS


def bezier(t):
    """The trail: a cubic curve from the start to the click."""
    points = (TRAIL_START, TRAIL_CONTROL_1, TRAIL_CONTROL_2, CLICK)
    u = 1 - t
    weights = (u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t)
    return (
        sum(w * p[0] for w, p in zip(weights, points)),
        sum(w * p[1] for w, p in zip(weights, points)),
    )


def trail_dots(count=8, clearance=196.0):
    """Dots evenly spaced along the curve (by length), stopping `clearance` px short of
    the click so they don't run into its rings; they grow and brighten toward it."""
    samples = [bezier(i / 2000) for i in range(2001)]
    lengths = [0.0]
    for a, b in zip(samples, samples[1:]):
        lengths.append(lengths[-1] + math.hypot(b[0] - a[0], b[1] - a[1]))
    end = next(i for i, point in enumerate(samples) if math.hypot(point[0] - CLICK[0], point[1] - CLICK[1]) < clearance)
    usable = lengths[end]
    dots = []
    cursor = 0
    for index in range(count):
        target = usable * index / (count - 1)
        while cursor < end and lengths[cursor] < target:
            cursor += 1
        x, y = samples[cursor]
        progress = index / (count - 1)
        dots.append((x, y, 12 + 12 * progress, 0.3 + 0.55 * progress))
    return dots


DOTS = trail_dots()
RINGS = [(112.0, 16.0, 0.55), (160.0, 10.0, 0.25)]
CLICK_RADIUS = 60.0


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
    shadow_distance = rounded_rect_distance(px, py - 14)
    shadow = 0.24 * clamp(1 - (shadow_distance + 6) / 34) if shadow_distance < 28 else 0.0
    pixel = over(pixel, (0, 0, 0), shadow)

    body_distance = rounded_rect_distance(px, py)
    body = coverage(body_distance)
    if body <= 0:
        return pixel

    # Diagonal gradient with a soft highlight in the top-left.
    t = clamp(((px - BODY_MIN) + (py - BODY_MIN)) / (2 * (BODY_MAX - BODY_MIN)))
    color = tuple(TOP_LEFT[i] + (BOTTOM_RIGHT[i] - TOP_LEFT[i]) * t for i in range(3))
    glow = clamp(1 - math.hypot(px - 260, py - 220) / 620) ** 2 * 0.22
    color = tuple(c + (255 - c) * glow for c in color)
    # A faint rim of light along the top edge.
    rim = clamp(1 - abs(body_distance + 3) / 3) * clamp((520 - py) / 400) * 0.35
    color = tuple(c + (255 - c) * rim for c in color)
    pixel = over(pixel, color, body)

    white = (255, 255, 255)
    for dot_x, dot_y, radius, alpha in DOTS:
        if abs(px - dot_x) < radius + 2 and abs(py - dot_y) < radius + 2:
            pixel = over(pixel, white, alpha * coverage(math.hypot(px - dot_x, py - dot_y) - radius))

    distance = math.hypot(px - CLICK[0], py - CLICK[1])
    for radius, width, alpha in RINGS:
        pixel = over(pixel, white, alpha * coverage(abs(distance - radius) - width / 2))
    pixel = over(pixel, white, coverage(distance - CLICK_RADIUS))
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
