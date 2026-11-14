#!/usr/bin/env python3
"""Ersatzbilder für die automatischen Playlists, solange dort noch keine Songs sind.

    python3 scripts/create-playlist-art.py

Schreibt nach ios/Miniply/Assets.xcassets. Reproduzierbar, das Rauschen hat einen
festen Startwert. Braucht NumPy und Pillow, die App selbst braucht beides nicht.
"""
import json
from pathlib import Path

import numpy as np
from PIL import Image

SIZE = 1200
OUTPUT = 720
ASSETS = Path(__file__).resolve().parents[1] / "ios/Miniply/Assets.xcassets"
axis = np.linspace(-1, 1, SIZE)
X, Y = np.meshgrid(axis, -axis)
FREQ_X, FREQ_Y = np.meshgrid(np.fft.fftfreq(SIZE), np.fft.fftfreq(SIZE))


def blur(image, sigma):
    gain = np.exp(-2 * (np.pi * sigma) ** 2 * (FREQ_X ** 2 + FREQ_Y ** 2))
    return np.real(np.fft.ifft2(np.fft.fft2(image) * gain))


def smooth(edge0, edge1, value):
    t = np.clip((value - edge0) / (edge1 - edge0), 0, 1)
    return t * t * (3 - 2 * t)


def rgb(text):
    return np.array([int(text[i:i + 2], 16) for i in (1, 3, 5)], dtype=float) / 255


def background(base, lights):
    """Weiche Farbflächen, wie Licht auf einer dunklen Wand."""
    image = np.ones((SIZE, SIZE, 3)) * rgb(base)
    for color, x, y, radius, strength in lights:
        glow = np.exp(-((X - x) ** 2 + (Y - y) ** 2) / (2 * radius ** 2))[..., None] * strength
        image = image * (1 - glow) + rgb(color) * glow
    vignette = 1 - 0.42 * smooth(0.55, 1.55, np.hypot(X, Y))
    return image * vignette[..., None]


def puffy(image, mask, top, bottom, shadow=0.55):
    """Legt die Form als weiches, glänzendes Objekt über das Bild."""
    offset = np.roll(blur(mask, 34), 34, axis=0)
    image = image * (1 - shadow * offset[..., None])
    height = sum(blur(mask, sigma) * weight for sigma, weight in ((10, 0.5), (28, 0.8), (60, 1.0)))
    dy, dx = np.gradient(height)
    scale = 16
    normal = np.dstack((-dx * scale, dy * scale, np.ones_like(dx)))
    normal /= np.linalg.norm(normal, axis=2, keepdims=True)
    light = np.array([-0.45, 0.62, 0.64])
    light /= np.linalg.norm(light)
    diffuse = np.clip(normal @ light, 0, 1)
    half = light + np.array([0, 0, 1.0])
    half /= np.linalg.norm(half)
    gloss = np.clip(normal @ half, 0, 1)
    span = (Y - Y[mask > 0.5].min()) / max(np.ptp(Y[mask > 0.5]), 1e-6) if (mask > 0.5).any() else Y
    color = rgb(bottom) + (rgb(top) - rgb(bottom)) * np.clip(span, 0, 1)[..., None]
    shaded = color * (0.42 + 0.72 * diffuse[..., None])
    shaded += 0.62 * (gloss ** 70)[..., None] + 0.14 * (gloss ** 12)[..., None]
    # Licht von hinten am unteren Rand, damit die Form nicht flach endet.
    rim = np.clip(-normal[..., 1], 0, 1) ** 2.2 * (1 - normal[..., 2]) ** 0.8
    shaded += (rgb(top) * 0.55)[None, None] * rim[..., None]
    alpha = smooth(0.45, 0.55, blur(mask, 1.4))[..., None]
    return image * (1 - alpha) + np.clip(shaded, 0, 1) * alpha


def bloom(image, mask, color, sigma, strength):
    return image + rgb(color) * blur(mask, sigma)[..., None] * strength


def finish(image, name):
    noise = np.random.default_rng(len(name) * 7919).normal(0, 0.012, (SIZE, SIZE, 1))
    data = np.clip(image + noise, 0, 1) ** (1 / 1.02)
    picture = Image.fromarray((data * 255 + 0.5).astype("uint8"), "RGB").resize((OUTPUT, OUTPUT), Image.LANCZOS)
    folder = ASSETS / f"{name}.imageset"
    folder.mkdir(exist_ok=True)
    picture.save(folder / f"{name}.jpg", quality=90, optimize=True, progressive=True)
    contents = {"images": [{"filename": f"{name}.jpg", "idiom": "universal"}],
                "info": {"author": "xcode", "version": 1}}
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    print(folder / f"{name}.jpg")


def heart():
    x, y = X / 0.53, (Y + 0.04) / 0.53
    y = y - 0.03
    field = (x ** 2 + y ** 2 - 1) ** 3 - x ** 2 * y ** 3
    mask = (field < 0).astype(float)
    image = background("#1a0614", [("#a3123f", -0.75, 0.75, 0.75, 0.95), ("#ff5c5c", 0.85, -0.85, 0.65, 0.75),
                                   ("#5a1a8c", 0.95, 0.75, 0.7, 0.7)])
    for radius, strength in ((0.78, 0.05), (0.92, 0.035)):
        ring = np.exp(-((np.hypot(X, Y) - radius) / 0.008) ** 2)
        image = image + ring[..., None] * strength
    image = bloom(image, mask, "#ff3d71", 90, 0.5)
    return puffy(image, mask, "#ff9db0", "#e0123f")


def rounded_box(left, right, bottom, top, radius):
    cx, cy = (left + right) / 2, (bottom + top) / 2
    qx = np.abs(X - cx) - ((right - left) / 2 - radius)
    qy = np.abs(Y - cy) - ((top - bottom) / 2 - radius)
    distance = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - radius
    return (distance < 0).astype(float)


def bars():
    width, gap, floor = 0.235, 0.08, -0.58
    start = -(4 * width + 3 * gap) / 2
    heights = (0.52, 0.86, 1.24, 0.70)
    mask = np.zeros((SIZE, SIZE))
    for index, height in enumerate(heights):
        left = start + index * (width + gap)
        mask = np.maximum(mask, rounded_box(left, left + width, floor, floor + height, 0.085))
    image = background("#050b24", [("#1fd1c1", -0.85, -0.8, 0.8, 0.85), ("#3a3df0", 0.85, 0.75, 0.8, 0.95),
                                   ("#7a2fd8", -0.8, 0.85, 0.55, 0.55)])
    image = bloom(image, mask, "#37e6d6", 90, 0.42)
    return puffy(image, mask, "#d6fff6", "#12b7c9")


def clock():
    distance = np.hypot(X, Y + 0.0)
    angle = np.mod(np.arctan2(Y, X), 2 * np.pi)
    radius, thickness = 0.53, 0.095
    # Der Ring läuft gegen den Uhrzeigersinn zurück und lässt oben links Platz für die Pfeilspitze.
    gap_from, gap_to = np.radians(150), np.radians(186)
    ring = (np.abs(distance - radius) < thickness / 2) & ~((angle > gap_from) & (angle < gap_to))
    tip = np.array([radius * np.cos(np.radians(150)), radius * np.sin(np.radians(150))])
    tangent = np.array([np.sin(np.radians(150)), -np.cos(np.radians(150))]) * -1
    outward = tip / np.linalg.norm(tip)
    a = tip + outward * 0.15 + tangent * 0.015
    b = tip - outward * 0.15 + tangent * 0.015
    c = tip - tangent * 0.2
    def side(p, q):
        return (X - p[0]) * (q[1] - p[1]) - (Y - p[1]) * (q[0] - p[0])
    s1, s2, s3 = side(a, b), side(b, c), side(c, a)
    arrow = ((s1 <= 0) & (s2 <= 0) & (s3 <= 0)) | ((s1 >= 0) & (s2 >= 0) & (s3 >= 0))
    hand_up = rounded_box(-0.042, 0.042, -0.04, 0.32, 0.042) > 0
    hand_side = rounded_box(-0.042, 0.25, -0.04, 0.044, 0.042) > 0
    mask = (ring | arrow | hand_up | hand_side).astype(float)
    image = background("#190a05", [("#ff8a1f", -0.85, -0.85, 0.85, 0.95), ("#c41f5c", 0.9, 0.8, 0.8, 0.9),
                                   ("#ffcf4a", -0.95, 0.75, 0.5, 0.42)])
    image = bloom(image, mask, "#ffb347", 90, 0.42)
    return puffy(image, mask, "#fff2c9", "#ff9416")


finish(heart(), "PlaylistFavorites")
finish(bars(), "PlaylistMostPlayed")
finish(clock(), "PlaylistRecent")
