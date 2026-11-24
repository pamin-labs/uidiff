#!/usr/bin/env python3
"""Build the bitmap table or verify the checked-in atlas offline.

--check verifies the committed output against its reproducible build digest.
--verify-generated compares a fresh rasterization byte for byte. Generation
uses Pillow 12.0.0 and FreeType 2.14.1. --font accepts the pinned TTF locally.
"""
import argparse
import hashlib
import io
import re
import struct
import urllib.request
from pathlib import Path

FONT_URL = (
    "https://raw.githubusercontent.com/google/fonts/"
    "8409f033cd7dee08914990602f0df5f5e70e0c14/ofl/ibmplexsans/"
    "IBMPlexSans%5Bwdth,wght%5D.ttf"
)
FONT_SHA256 = "3b031aa4216174205bd8471f88a49b91f093169e9e87bd5262242bc5967fe2e3"
OUTPUT = Path(__file__).resolve().parents[1] / "src/annotate/font-ascii.bin"
ATLAS_SHA256 = "89db506d98b89a4033006923a2aa0293ec3714bc75373e732a88d44a4e0f5cf1"


def metrics():
    text = OUTPUT.with_name("text.zig").read_text()
    names = ("regular_em", "regular_height", "bold_em", "bold_height", "ascii_first", "ascii_last")
    return tuple(int(re.search(rf"^const {name} = ([0-9]+);$", text, re.M).group(1)) for name in names)


def atlas(source, size, height, weight, labels, first, last):
    from PIL import Image, ImageDraw, ImageFont
    font = ImageFont.truetype(io.BytesIO(source), size)
    axes = font.get_variation_axes()
    font.set_variation_by_axes([weight if axis["name"] == b"Weight" else axis["default"] for axis in axes])
    table = bytearray()
    glyphs = {}
    for glyph in sorted(set(labels + "?")):
        raster = Image.new("L", (size + 4, height))
        # The regular atlas uses two unused internal caption slots.
        character = {"|": "·", "-": "–"}.get(glyph, glyph) if weight == 400 else glyph
        ImageDraw.Draw(raster).text((1, size), character, font=font, fill=255, anchor="ls")
        left, top, right, bottom = raster.getbbox() or (0, 0, 0, 0)
        coverage = [(value + 8) // 17 for value in raster.crop((left, top, right, bottom)).getdata()]
        if len(coverage) % 2:
            coverage.append(0)
        glyphs[glyph] = len(table)
        table.extend((round(font.getlength(character)), left, top, right - left, bottom - top))
        table.extend(low | high << 4 for low, high in zip(coverage[::2], coverage[1::2]))
    indices = [glyphs.get(chr(code), glyphs["?"]) for code in range(first, last + 1)]
    return struct.pack(f"<{len(indices)}H", *indices) + table


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--font", type=Path)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--verify-generated", action="store_true")
    args = parser.parse_args()
    layout = metrics()
    if args.check:
        if hashlib.sha256(bytes(layout) + args.output.read_bytes()).hexdigest() != ATLAS_SHA256:
            parser.error("the committed glyph table differs from the pinned rasterization")
        return
    from PIL import __version__ as pillow_version, features
    if pillow_version != "12.0.0" or features.version_module("freetype2") != "2.14.1":
        parser.error("generation requires Pillow 12.0.0 and FreeType 2.14.1")
    if args.font:
        source = args.font.read_bytes()
    else:
        with urllib.request.urlopen(FONT_URL, timeout=30) as response:
            source = response.read()
    if hashlib.sha256(source).hexdigest() != FONT_SHA256:
        parser.error("the upstream font SHA-256 does not match")
    regular_em, regular_height, bold_em, bold_height, first, last = layout
    regular = atlas(source, regular_em, regular_height, 400, "changed inserted removed not on this side Before After | x 0123456789- scaled %", first, last)
    bold = atlas(source, bold_em, bold_height, 700, "0123456789+- px, changes blocks moved down up Before After Changes up close Each change at full size", first, last)
    output = struct.pack("<H", len(regular)) + regular + bold
    if args.verify_generated:
        if args.output.read_bytes() != output:
            parser.error("the committed glyph table differs from a fresh generation")
    else:
        args.output.write_bytes(output)


if __name__ == "__main__":
    main()
