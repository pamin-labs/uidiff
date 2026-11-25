---
name: uidiff
description: Compare two UI screenshots after a change, verify an agent's visual edit, or run a CI visual check. Use uidiff to get numbered change regions, vertical moves, and an annotated PNG.
---

# Compare UI captures with uidiff

Use this when there is a baseline capture and a new capture of the same UI.
For an edit, capture the baseline before changing the UI. In CI, keep the
baseline and candidate in the same capture environment.

## Capture a comparable pair

- Use the same viewport width, device scale, zoom, locale, fonts and theme.
  Different heights are fine when the height change is part of the comparison.
- Start at the same scroll position and reproduce the same route, input state
  and test data. Wait for fonts, images and layout to settle.
- Freeze animations, carets, timers and dynamic data. Capture the relevant
  area on both sides. Prefer lossless PNG to avoid compression noise.

## Run the comparison

```sh
uidiff before.png after.png --scale 2 --json --annotate sheet.png > report.json
```

Inputs can be PNG, JPEG or WebP. Set `--scale` to the capture's device pixels
per logical pixel, such as `2` for a 2× capture. It defaults to `1` and sets
padding and merge distances. The reported coordinates stay in device pixels.
Omit `--json` for a region count or `--annotate` when only the report is needed.

| Exit | Meaning |
| --- | --- |
| `0` | No change regions were detected. Read `moves` if placement matters. |
| `1` | Change regions were detected. Read the report and inspect the sheet. |
| `2` | An error occurred. Check stderr and treat the comparison as failed. |

Handle all three statuses in CI. If the shell exits on errors, capture the
status explicitly, for example with `status=0; uidiff ... || status=$?`.

## Read the report and sheet

- Check `version` before consuming a schema. Version 1 gives the maximum
  input width and height and two arrays, `regions` and `moves`.
- A region has a `number` matching its sheet label and a `kind` of
  `changed`, `inserted` or `removed`. Its `before` and `after` boxes have
  `x`, `y`, `width` and `height`, measured from the top left of their
  respective images. The absent side of an insertion or removal is `null`.
- Each move has `before` and `after` row ranges (`y`, `height`) and an
  `x` and `width` for the affected columns. Compute the signed vertical
  offset as `after.y - before.y`. Positive offsets move down.
- The sheet shows before and after panes, amber changed boxes, green
  inserted boxes and red removed boxes. The gutter shows stationary and
  shifted rows. Match the numbered close-ups to the report.

Compare the regions with the intended edit and inspect unexpected regions
in both captures. Boxes locate visual evidence and can include padding or
group nearby edits. Row alignment can explain a displacement while leaving
the shifted content without a change box. Identical-looking results can
still differ in behavior, accessibility or DOM structure. A capture covers
only its visible state, and subtle differences can fall below pixel and
region thresholds.
