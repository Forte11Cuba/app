#!/usr/bin/env python3
"""Build the avatar icon font from the 64 animal SVGs.

The chat avatar draws the animal of a pseudonym (`rust/src/crypto/nym.rs`,
`NOUNS`) as a glyph of this font: an `Icon` renders synchronously, unlike an
SVG decoded at runtime. Glyph `i` sits at U+E000 + i, where `i` is the
animal's index in `NOUNS`; `lib/shared/widgets/nym_avatar.dart` keeps the same
list, and `test/shared/nym_animals_test.dart` holds the three in step.

The drawings are Fluent Emoji High Contrast (Microsoft, MIT): see
`assets/fonts/nym_animals/LICENSE.txt`.

Run after changing an SVG or the animal list:

    python3 -m venv /tmp/nym-venv
    /tmp/nym-venv/bin/pip install fonttools picosvg skia-pathops
    /tmp/nym-venv/bin/python tool/nym_animals/build_font.py

picosvg flattens clip paths, masks and strokes into plain filled paths, and
skia-pathops merges them into one non-zero outline per glyph: TrueType has no
clip paths and no even-odd fill.
"""

import re
import sys
from pathlib import Path

import pathops
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.svgLib.path import parse_path
from picosvg.svg import SVG

ROOT = Path(__file__).resolve().parents[2]
SVG_DIR = Path(__file__).resolve().parent / "svg"
OUT = ROOT / "assets/fonts/nym_animals/NymAnimals.ttf"
FAMILY = "NymAnimals"
FIRST_CODEPOINT = 0xE000
UPM = 1024
VIEWBOX = 32  # every source SVG is drawn on a 32 x 32 box
SCALE = UPM / VIEWBOX


def nouns() -> list[str]:
    """The animal list, in order, read from the Rust source of truth."""
    source = (ROOT / "rust/src/crypto/nym.rs").read_text()
    block = source.split("const NOUNS: [&str; 64] = [", 1)[1].split("];", 1)[0]
    names = re.findall(r'"([a-z]+)"', block)
    assert len(names) == 64 and len(set(names)) == 64, names
    return names


def masks_as_clip_paths(source: str) -> str:
    """A mask filled solid white is a clip path, which picosvg can flatten."""
    source = re.sub(r'<mask (id="[^"]+") fill="#fff">(.*?)</mask>',
                    r"<clipPath \1>\2</clipPath>", source, flags=re.S)
    assert "<mask" not in source, "only solid white masks are supported"
    return source.replace("mask=\"url(", "clip-path=\"url(")


def outline(svg_file: Path) -> pathops.Path:
    """The SVG's filled area as one non-zero path, in SVG coordinates."""
    pico = SVG.fromstring(masks_as_clip_paths(svg_file.read_text())).topicosvg()
    union = pathops.Path()
    for shape in pico.shapes():
        fill = (shape.fill or "").lower()
        assert fill in ("currentcolor", "black", "#000", "#000000"), (svg_file, fill)
        path = pathops.Path()
        parse_path(shape.d, path.getPen())
        if shape.fill_rule == "evenodd":
            path.fillType = pathops.FillType.EVEN_ODD
        path.simplify(fix_winding=True)
        union = pathops.op(union, path, pathops.PathOp.UNION, fix_winding=True)
    return union


def glyph(svg_file: Path):
    pen = TTGlyphPen(None)
    # SVG y grows downwards, font y upwards: flip inside the em square.
    flip = TransformPen(Cu2QuPen(pen, max_err=1.0, reverse_direction=True),
                        (SCALE, 0, 0, -SCALE, 0, UPM))
    outline(svg_file).draw(flip)
    return pen.glyph()


def main() -> int:
    names = nouns()
    missing = [n for n in names if not (SVG_DIR / f"{n}.svg").exists()]
    extra = sorted({p.stem for p in SVG_DIR.glob("*.svg")} - set(names))
    if missing or extra:
        print(f"missing SVGs: {missing}; SVGs for no animal: {extra}", file=sys.stderr)
        return 1

    order = [".notdef"] + names
    glyphs = {".notdef": TTGlyphPen(None).glyph()}
    glyphs.update({n: glyph(SVG_DIR / f"{n}.svg") for n in names})

    fb = FontBuilder(UPM, isTTF=True)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap({FIRST_CODEPOINT + i: n for i, n in enumerate(names)})
    fb.setupGlyf(glyphs)  # also computes each glyph's bounds
    # TrueType puts a glyph's origin at xMin - lsb: any left side bearing other
    # than xMin moves the drawing in its advance (FreeType draws it flush left).
    fb.setupHorizontalMetrics({n: (UPM, glyphs[n].xMin) for n in order})
    fb.setupHorizontalHeader(ascent=UPM, descent=0)
    fb.setupNameTable({"familyName": FAMILY, "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=UPM, sTypoDescender=0, sTypoLineGap=0,
                usWinAscent=UPM, usWinDescent=0)
    fb.setupPost()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    fb.save(str(OUT))
    print(f"{OUT.relative_to(ROOT)}: {len(names)} glyphs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
