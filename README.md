<h1 align="center">uidiff</h1>

<p align="center"><b>What changed between two screenshots, at a glance.</b><br>
Compare two captures and get a sheet with detected changes boxed, numbered and labelled.</p>

<p align="center">
  <img src="docs/images/dashboard-desktop-light.png" alt="uidiff's sheet for a desktop dashboard: before and after side by side, three numbered changes, a gutter showing the rows that moved down, and a close-up of each change" width="100%">
</p>

You change a UI, or a script does, or an AI agent does, and now you need to know what actually changed. A pixel diff tells you which pixels differ, so one inserted row paints everything below it. uidiff tells you what changed: it lines up rows that only moved, boxes each real edit, labels it **changed**, **inserted** or **removed**, and reports how far the rest moved. It reads nothing but the two images, so the same command works for websites, iOS and Android apps, desktop apps, games, canvas and mini programs. It earns its keep wherever a UI is iterated on, and most of all in vibe coding, where the screen changes every few minutes and you need to see what the agent really did.

## Why uidiff

**One native binary and a report with labelled changes.** In the CLI comparison below, uidiff took less time and peak memory than pixelmatch, odiff and Iris. The accuracy rows cover 115 real and synthetic screenshot pairs with hand-checked ground truth. Pixel masks were grouped into boxes for scoring.

| | uidiff | Iris | odiff | pixelmatch |
| --- | ---: | ---: | ---: | ---: |
| Pairs whose changes come out exactly right | **111 / 115** | 60 / 115 | 49 / 115 | 49 / 115 |
| Boxes on things that did not change | **4** | 46 | 147 | 131 |
| Moved content found with its offset | **56 / 56** | 56 / 56 | n/a | n/a |
| What you get | labelled regions, moves, a sheet | a mask | a mask | a mask |
| CLI time, 2560×1600 pair | **11 ms** | 65 ms | 103 ms | 379 ms |
| CPU time, same pair | **15 ms** | 80 ms | 127 ms | 419 ms |
| Peak memory | **35 MB** | 70 MB | 50 MB | 147 MB |
| Install | **605 KB**, one file | 1.3 MB + Node | 2.4 MB | 0.76 MB + Node |

<sub>Timings are medians from 15 rotated rounds on an Apple M4. Each comparison starts a new process. uidiff writes JSON, and Iris and pixelmatch include Node startup. See the <a href="bench/README.md">benchmark method</a>.</sub>

## The sheet

`--annotate sheet.png` draws before and after panes, with numbered boxes in amber for changed regions, green for insertions and red for removals. The gutter shows stationary and shifted rows. Numbered close-ups appear below the panes. Panoramic captures use stacked overview strips.

<table>
  <tr>
    <td width="50%"><img src="docs/images/chat-phone-light.png" alt="Phone chat: a new message pushes the thread down; one inserted box, the rest marked as moved"></td>
    <td width="50%"><img src="docs/images/settings-phone-light.png" alt="Phone settings: a toggle and a label changed in place, each boxed, numbered and shown close up"></td>
  </tr>
  <tr>
    <td align="center"><sub>A new message: one green box, and the thread below it shown as moved, not changed.</sub></td>
    <td align="center"><sub>Edits in place: each one boxed, numbered and shown close up.</sub></td>
  </tr>
  <tr>
    <td colspan="2"><img src="docs/images/pricing-desktop-dark.png" alt="Desktop pricing page in dark mode with three numbered changes and a moved block"></td>
  </tr>
  <tr>
    <td colspan="2" align="center"><sub>Dark mode, desktop: three changes and a block that moved 128 px, in one picture.</sub></td>
  </tr>
</table>

## The report

`--json` prints each region's number, kind and box on each side, the before and after row ranges for moved content, and the canvas size. Subtract the before row's `y` from the after row's `y` for the signed offset. The exit code distinguishes a clean comparison, detected change regions and errors.

## Install

On macOS and Linux (x64 or arm64):

```sh
curl -fsSLO https://github.com/pamin-labs/uidiff/releases/latest/download/install.sh
sh install.sh
```

On Windows (x64 or arm64) in PowerShell:

```powershell
Invoke-WebRequest -UseBasicParsing https://github.com/pamin-labs/uidiff/releases/latest/download/install.ps1 -OutFile install.ps1
.\install.ps1
```

The installers verify the binary against `SHA256SUMS` and print the installed
path under `~/.local/bin` or `%LOCALAPPDATA%\Programs\uidiff`. Set
`UIDIFF_VERSION` to select a specific release, with or without the leading `v`.

For npm projects, run `npm install --save-dev uidiff` and use `npx uidiff`.
npm selects the platform binary through optional dependencies.

The [releases page](https://github.com/pamin-labs/uidiff/releases) also has
standalone binaries, archives with license notices, checksums and the rendered
`uidiff.rb` formula for use in a Homebrew tap.

## Use

```text
uidiff <before> <after> [--scale N] [--json] [--annotate <out.png>]
uidiff --help
```

| Argument | Meaning |
| --- | --- |
| `<before>`, `<after>` | The two captures: PNG, JPEG or WebP. Different heights are fine; a different width is reported as added or removed columns. |
| `--scale N` | Device pixels per logical pixel (CSS px, points or dp), as a plain decimal such as `2` or `1.5`. Default `1`. It sets padding and merge distances in logical pixels; boxes stay in device pixels. |
| `--json` | Print the report as one JSON object instead of the region count. |
| `--annotate <out.png>` | Also write the sheet to this PNG. The file is replaced only once the sheet is complete. |
| `--help` | Print usage and exit 0. |

| Exit code | Meaning |
| --- | --- |
| `0` | No change regions detected. |
| `1` | Change regions found. |
| `2` | A comparison or usage error, reported on stderr. |

```sh
uidiff before.png after.png --scale 2                          # "3 regions"
uidiff before.png after.png --scale 2 --json > report.json
uidiff before.png after.png --scale 2 --annotate sheet.png
```

For the best results, freeze animations, carets and timers, and keep fonts, locale and device scale the same for both captures.

## Agent skill

The uidiff skill teaches agents that read `SKILL.md` how to capture a comparable pair, run the CLI and interpret the report.

```sh
npx skills add pamin-labs/uidiff        # install into this project (-g for every project)
npx skills update                       # update installed skills to their latest version
npx skills remove uidiff                # remove it
```

Inside a project the skill is recorded in `skills-lock.json`; commit it, and `npx skills install` restores the same version on another machine.
