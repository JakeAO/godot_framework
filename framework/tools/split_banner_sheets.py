#!/usr/bin/env python3
"""Split the banner spritesheets into individual grayscale PNGs (TDD §3.19).

Grid-aware split: the alpha mask is projected onto both axes and fully-empty
gap lines separate content runs into column/row bands. The EXPECTED grid is
passed in; if the projection does not yield exactly that many bands the tool
aborts with diagnostics instead of writing garbage (the sheets are
non-uniform, so fixed-pitch slicing is not an option).

Usage:
  python3 tools/split_banner_sheets.py <sheet.png> <outdir> <prefix> <cols> <rows> [target_w target_h]

- With target_w/target_h every crop is LANCZOS-resized to that uniform size
  (banner bases → 256x512, 1:2 portrait — hanging-flag pennant style; the
  TeamBannerView display slots match this aspect).
- Without them crops keep their native scale (icons).
Output naming: row-major from top-left, <prefix>_01 .. <prefix>_NN.
"""

import sys
from pathlib import Path

import numpy as np
from PIL import Image

ALPHA_THRESHOLD = 8  # ignore sub-threshold AA tails / stray specks


def bands(projection):
    """Maximal runs of positions with ink -> list of (start, end_exclusive)."""
    out = []
    start = None
    for i, v in enumerate(projection):
        if v > 0 and start is None:
            start = i
        elif v == 0 and start is not None:
            out.append((start, i))
            start = None
    if start is not None:
        out.append((start, len(projection)))
    return out


def split_sheet(path, cols_expected, rows_expected):
    im = Image.open(path).convert("RGBA")
    mask = np.asarray(im.getchannel("A"), dtype=np.uint8) > ALPHA_THRESHOLD
    col_ink = mask.sum(axis=0)
    row_ink = mask.sum(axis=1)
    col_bands = bands(col_ink)
    row_bands = bands(row_ink)
    if len(col_bands) != cols_expected:
        sys.exit(
            "FAIL %s: found %d column bands, expected %d"
            % (path, len(col_bands), cols_expected)
        )
    if len(row_bands) != rows_expected:
        sys.exit(
            "FAIL %s: found %d row bands, expected %d"
            % (path, len(row_bands), rows_expected)
        )
    crops = []
    for y0, y1 in row_bands:
        for x0, x1 in col_bands:
            cell = mask[y0:y1, x0:x1]
            if not cell.any():
                sys.exit(
                    "FAIL %s: empty cell at row-band (%d,%d) col-band (%d,%d)"
                    % (path, y0, y1, x0, x1)
                )
            ys, xs = np.where(cell)
            crops.append(
                im.crop(
                    (
                        x0 + int(xs.min()),
                        y0 + int(ys.min()),
                        x0 + int(xs.max()) + 1,
                        y0 + int(ys.max()) + 1,
                    )
                )
            )
    return crops


def main(argv):
    if len(argv) not in (6, 8):
        sys.exit(__doc__)
    sheet, outdir, prefix = argv[1], Path(argv[2]), argv[3]
    cols, rows = int(argv[4]), int(argv[5])
    target = (int(argv[6]), int(argv[7])) if len(argv) == 8 else None

    crops = split_sheet(sheet, cols, rows)
    outdir.mkdir(parents=True, exist_ok=True)
    aspects = []
    for i, crop in enumerate(crops, start=1):
        img = crop.resize(target, Image.LANCZOS) if target else crop
        name = "%s_%02d.png" % (prefix, i)
        img.save(outdir / name)
        w, h = crop.size
        aspects.append(w / float(h))
        flag = ""
        if not target and (w / float(h) < 0.4 or w / float(h) > 2.5):
            flag = "  <-- odd aspect"
        print("%s %dx%d%s" % (name, img.size[0], img.size[1], flag))
    print("WROTE %d files to %s" % (len(crops), outdir))
    print(
        "source-crop aspects: min %.2f / median %.2f / max %.2f"
        % (min(aspects), float(np.median(aspects)), max(aspects))
    )


if __name__ == "__main__":
    main(sys.argv)
