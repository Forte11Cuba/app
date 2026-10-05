#!/usr/bin/env python3
"""Build the launcher icon and splash sources from the mascot disc.

v2 ships the same mascot as the v1 app (MostroP2P/mobile), so on a phone with
both installed the two icons were identical. v2 adds a metallic gold ring
inside the disc's edge; the mascot and the background stay as they are.

`mascot-disc.png` (next to this script) is the v1 artwork without the ring:
the dark disc on a transparent 1024 px square. This script writes:

- `assets/images/launcher-icon.png`: the disc with the ring, still on a
  transparent square (Android legacy icon, adaptive foreground).
- `assets/images/launcher-icon-ios.png`: the same, flattened onto the brand
  background, since iOS forbids an alpha channel in app icons.
- `assets/images/launcher-icon-web.png`: the iOS art at 80 % on that
  background, so Android's maskable crop keeps the bolt's tip and the ring.
- `android/app/src/main/res/drawable-*/splash_logo.png`: the ringed disc at
  160 dp, the launch screen logo below Android 12 (12+ draws the adaptive
  icon itself, at the same size).
- `ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage*.png`: the
  ringed disc at 160 pt, the iOS launch screen logo.

Then regenerate the launcher icons from the first three (see the
`flutter_launcher_icons` block in pubspec.yaml). Needs only Pillow:

    python3 tool/launcher_icon/build_sources.py
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).with_name('mascot-disc.png')

SIZE = 1024
# The adaptive icon's background, which the disc's own fill matches.
BRAND_BACKGROUND = (0x1D, 0x21, 0x2C)
# Outer edge 20 px inside the disc, so a launcher's circular mask (which
# trims the adaptive foreground to about 98 % of the disc) never clips it,
# and 34 px wide, enough to read at 48 px; inside sits clear of the ears.
RING_OUTER_RADIUS = 492
RING_WIDTH = 34
# Light top-left to dark, with a highlight back at the bottom-right edge.
GOLD_STOPS = [
    (0.0, (255, 236, 160)),
    (0.35, (233, 190, 80)),
    (0.65, (196, 146, 40)),
    (1.0, (245, 210, 110)),
]
SUPERSAMPLING = 4
WEB_SCALE = 0.8
SPLASH_LOGO_DP = 160
ANDROID_DENSITIES = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}
IOS_SCALES = {'': 1, '@2x': 2, '@3x': 3}


def gold_gradient():
    """A diagonal gold gradient filling the whole square."""
    ramp = []
    for i in range(2 * SIZE - 1):
        t = i / (2 * SIZE - 2)
        for (t0, c0), (t1, c1) in zip(GOLD_STOPS, GOLD_STOPS[1:]):
            if t0 <= t <= t1:
                k = (t - t0) / (t1 - t0)
                ramp.append(tuple(round(a + (b - a) * k) for a, b in zip(c0, c1)))
                break
    image = Image.new('RGB', (SIZE, SIZE))
    image.putdata([ramp[x + y] for y in range(SIZE) for x in range(SIZE)])
    return image


def ring_mask():
    """The ring as an antialiased mask, drawn large and scaled down."""
    big = SIZE * SUPERSAMPLING
    centre = big / 2
    outer = RING_OUTER_RADIUS * SUPERSAMPLING
    inner = (RING_OUTER_RADIUS - RING_WIDTH) * SUPERSAMPLING
    mask = Image.new('L', (big, big), 0)
    draw = ImageDraw.Draw(mask)
    draw.ellipse((centre - outer, centre - outer, centre + outer, centre + outer), fill=255)
    draw.ellipse((centre - inner, centre - inner, centre + inner, centre + inner), fill=0)
    return mask.resize((SIZE, SIZE), Image.LANCZOS)


def ringed_disc():
    disc = Image.open(SOURCE).convert('RGBA')
    ring = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    ring.paste(gold_gradient(), (0, 0), ring_mask())
    return Image.alpha_composite(disc, ring)


def on_background(image, scale=1.0):
    square = Image.new('RGBA', (SIZE, SIZE), BRAND_BACKGROUND + (255,))
    side = round(SIZE * scale)
    offset = (SIZE - side) // 2
    square.alpha_composite(image.resize((side, side), Image.LANCZOS), (offset, offset))
    return square.convert('RGB')


def save_scaled(image, side, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    image.resize((side, side), Image.LANCZOS).save(path, optimize=True)


def main():
    disc = ringed_disc()
    images = ROOT / 'assets' / 'images'
    disc.save(images / 'launcher-icon.png', optimize=True)
    ios = on_background(disc)
    ios.save(images / 'launcher-icon-ios.png', optimize=True)
    on_background(ios.convert('RGBA'), WEB_SCALE).save(images / 'launcher-icon-web.png', optimize=True)

    res = ROOT / 'android' / 'app' / 'src' / 'main' / 'res'
    for density, factor in ANDROID_DENSITIES.items():
        side = round(SPLASH_LOGO_DP * factor)
        save_scaled(disc, side, res / f'drawable-{density}' / 'splash_logo.png')

    launch = ROOT / 'ios' / 'Runner' / 'Assets.xcassets' / 'LaunchImage.imageset'
    for suffix, factor in IOS_SCALES.items():
        save_scaled(disc, SPLASH_LOGO_DP * factor, launch / f'LaunchImage{suffix}.png')


if __name__ == '__main__':
    main()
