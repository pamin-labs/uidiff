---
name: uidiff
description: Find out exactly what changed between two screenshots of a UI, with numbered boxes for changed, inserted and removed content and the offset of anything that only moved. Use it whenever you change anything visible (a web page, component, CSS, iOS or Android screen, desktop app, game or canvas) and need to verify the result, when the user asks what changed, whether an edit broke the layout or did more than intended, when reviewing a PR's before and after screenshots, or when setting up a visual regression check in CI, even if they never say "uidiff" or "diff".
---

# Compare UI captures with uidiff

uidiff reads two images of the same screen and reports what really changed.
Content that only moved (because something above it was inserted or removed)
is aligned and reported as a shift, so only real edits get a box. That is why
it beats eyeballing two screenshots or a pixel diff: you learn which edits
happened, including ones nobody mentioned.

## 1. Make sure uidiff runs

Check the installed version with `uidiff --version`. If uidiff is missing:

- In a project with a `package.json`, add it pinned so CI uses the same
  version: `npm install --save-dev @pamin-labs/uidiff`, then run `npx uidiff`.
- Otherwise install the binary: `curl -fsSL https://uidiff.paminlabs.com/install.sh | sh`
  on macOS and Linux (installs to `~/.local/bin`),
  `irm https://uidiff.paminlabs.com/install.ps1 | iex` on Windows, or
  `brew install pamin-labs/tap/uidiff`.

## 2. Capture the baseline before you edit

The baseline must show the UI as it was. If you are about to change UI code,
capture first. If the edit is already made, rebuild the old state instead of
guessing: `git stash` (or check out the base commit in a worktree), capture,
then restore your changes and capture again.

Keep the two captures comparable, or the report fills with noise that is not
your change:

- Same viewport width, device scale, zoom, theme, locale, fonts and test data.
- Same route, scroll position and UI state. Wait for fonts, images and
  network to settle.
- Freeze what moves on its own: animations, carets, clocks, relative times,
  random avatars. Prefer PNG; JPEG artefacts show up as tiny changes.

| Platform | Capture |
| --- | --- |
| Web (Playwright) | `await page.screenshot({ path: "before.png", fullPage: true, animations: "disabled", caret: "hide" })` |
| iOS Simulator | `xcrun simctl io booted screenshot before.png` |
| Android | `adb exec-out screencap -p > before.png` |
| Anything else | The platform's own screenshot tool, at a fixed window size |

## 3. Run it

```sh
uidiff before.png after.png --scale 2 --json --annotate sheet.png > report.json
```

Pass captures as files. `-` does not read stdin, and input pipes are unsupported.
For many pairs, `uidiff --batch` reads one JSON request per stdin line
(`{"before":"a.png","after":"b.png","scale":"2","annotate":"sheet.png"}`) and
prints one line per request, `{"status":N,"report":{...}}` or
`{"status":2,"error":"FileNotFound","path":"a.png"}`, faster than one process
per pair.
A symlink at the sheet path is replaced by the PNG itself, unless it points to
an input, which raises `SheetIsInput`.

`--scale` is device pixels per logical pixel: Playwright's `deviceScaleFactor`,
`2` or `3` for iOS Retina screenshots, the screen density for Android (for
example `2.625`). If unsure, divide the image width by the viewport's CSS or
point width. It only tunes padding and merge distances, so a close guess is
fine; coordinates are always in device pixels.

| Exit | Meaning |
| --- | --- |
| `0` | No change regions. `moves` may still list shifted content. |
| `1` | Change regions found: read the report and look at the sheet. |
| `2` | Error. Read stderr for the failing path or argument. `SheetIsInput` means the sheet path names either input, including through a link. |

Exit 1 is a result, not a failure. In scripts that stop on errors, capture
it with `status=0; uidiff ... || status=$?`, then fail on `2`, and on `1`
only when the check requires no change.

## 4. Read the result

Look at `sheet.png` first; it is the fastest way to understand the change.
Before and after panes sit side by side with numbered boxes: amber for
changed, green for inserted, red for removed. The gutter between them shows
which rows stayed and which shifted, with the offset. Below, each numbered
change has a close-up of both sides.

`report.json` (version 1) carries the same numbers. This excerpt shows two regions and one move.

```json
{ "version": 1,
  "regions": [
    { "number": 1, "kind": "removed", "before": { "x": 1531, "y": 787, "width": 857, "height": 165 }, "after": null },
    { "number": 2, "kind": "changed", "before": { "x": 1746, "y": 1114, "width": 642, "height": 204 },
      "after": { "x": 1746, "y": 924, "width": 642, "height": 204 } } ],
  "width": 2560, "height": 1600,
  "moves": [ { "before": { "y": 968, "height": 366 }, "after": { "y": 778, "height": 366 }, "x": 860, "width": 1520 } ] }
```

A region's absent side is `null`. A move's signed offset is
`after.y - before.y` (positive moves down). Check `version` before relying
on the shape.

Connected changes smaller than four pixels are treated as noise. If the
smaller capture has at most 1024 pixels, single-pixel regions can be reported.

## 5. Report back

Match every region to the intended change and say plainly which were
expected and which were not. Unexpected regions are the point of the
exercise: look at both captures for each one and either explain it or treat
it as a regression to fix. Mention large shifts too, since content jumping
by 200 px can matter even without a box.

A screenshot cannot show everything: boxes are padded and may group nearby
edits, very faint differences can fall under the threshold, and identical
pixels say nothing about behaviour, accessibility or hidden state. When you
share the result with a person (a PR, a chat), attach `sheet.png`; it
explains itself.
