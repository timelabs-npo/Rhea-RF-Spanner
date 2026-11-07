#!/usr/bin/env python3
"""Regenerate the geometric app icon. Optional dependency: Pillow.

The PNG is committed; building the app does not require Python or Pillow.
"""
from pathlib import Path
from math import sin, pi
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[1]
scale = 2
image = Image.new("RGB", (1024 * scale, 1024 * scale), "#071521")
draw = ImageDraw.Draw(image)
for radius, color, width in ((350, "#123A4D", 3), (260, "#1D5B73", 4)):
    draw.ellipse(tuple(v * scale for v in (512-radius, 512-radius, 512+radius, 512+radius)), outline=color, width=width*scale)
points = [(x*scale, (512 - 145*sin((x-176)/672*2*pi))*scale) for x in range(176, 849)]
draw.line(points, fill="#56E2E8", width=22*scale, joint="curve")
for x, y in (points[0], points[-1]):
    draw.ellipse((x-11*scale, y-11*scale, x+11*scale, y+11*scale), fill="#56E2E8")
draw.ellipse((492*scale, 492*scale, 532*scale, 532*scale), fill="#FFFFFF")
image.resize((1024, 1024), Image.Resampling.LANCZOS).save(root / "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png", optimize=True)
print("Generated opaque 1024×1024 RGB AppIcon.png.")

