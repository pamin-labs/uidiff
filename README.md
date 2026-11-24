# uidiff

Screenshot diffs for any front end: pixels in, numbered regions out. uidiff compares two captures of the same screen, aligns rows that only moved, so content pushed down by an insertion is not reported as changed, and boxes the real changes as numbered regions in JSON. It reads only the images, so it needs no DOM or view tree: websites, iOS and Android apps (simulator or emulator captures such as `xcrun simctl io booted screenshot` and `adb exec-out screencap -p`), desktop apps, games and canvas, and mini programs and mini games captured by their dev tools all work the same way.

Status: in development, not yet released.

## Usage

Build with the Zig version pinned in `build.zig.zon`.

```sh
zig build
zig-out/bin/uidiff before.png after.png --scale 2 --json
zig-out/bin/uidiff before.png after.png --scale 3 --annotate sheet.png
```

Inputs can be PNG, JPEG, or WebP. `--scale` takes the number of device pixels per logical pixel (CSS pixels, points or dp) as a plain decimal (`2`, `1.5`) and defaults to 1. `--scale 0` fails with `InvalidScale`. Other invalid values, including numbers too large for a 64-bit float, print the usage text. Without `--json`, the command prints the region count (`1 region`, `3 regions`).

`--annotate <out.png>` writes a PNG with labelled before and after panes. Amber marks changes, green marks insertions, and red marks removals. The gutter shows stationary rows in grey and displaced rows in blue with their signed shift. Green and red wedges lead into the shifted rows. When columns align independently, the gutter shows the column with the largest moved block. Below the panes, each region has a numbered close-up with context from each affected side.

Panoramic comparisons use two labelled overview strips and paired focus rows. Focus crops show the original x ranges and retain full-size pixels wherever they fit. Reduced crops show their scale in the caption, and overlapping crops share a focus row. For other aspect ratios, small panes use integer enlargement where the sheet bounds permit it, and tall previews fit within a height cap. Crops use an area filter when downscaled. JSON boxes and shift labels use original device pixels.

The CLI streams the sheet one row at a time and replaces the destination only when the PNG is complete. An identical pair still writes a sheet and exits with status 0. The rendered preview and detail layout must fit within the sheet bounds. An output that exceeds them fails with `SheetTooLarge`. A directory destination fails with `IsDir`.

`--help` prints usage to standard output and exits with 0. The exit code is 0 for no regions, 1 for changed images, and 2 for errors, including a failure to write standard output. Errors are one line on standard error naming the file concerned (or `stdout`) and a stable error name, such as `error(uidiff): after.png: ImageTooLarge`. The CLI's text is English only; programs should read the JSON report and the error names.

### Good input

- Freeze animations, carets, timers and random content before capturing.
- Fix fonts, the locale and the device scale between the two captures.
- Compare captures of the same width and scale. Different heights are fine; a different width is reported as added or removed columns.

### JSON report

With `--json`, the command prints one object:

- `version`: the report schema version.
- `width`, `height`: the larger width and the larger height of the two inputs.
- `regions`: the changes, numbered from 1 in reading order. Each has a `number`, a `kind` and one box per side:
  - `kind` is `changed` (the region is on both sides), `inserted` (only on the after side) or `removed` (only on the before side). Later versions may add kinds, so treat an unknown one as `changed`.
  - `before` and `after` are boxes with `x`, `y`, `width` and `height`. A side the region is not on is `null`.
- `moves`: aligned blocks whose vertical positions differ. Each block has `before` and `after` row ranges with `y` and `height`, plus `x` and `width` identifying the columns they cover. The signed shift is `after.y - before.y`. The array is empty when the comparison finds no row movement. This field is additive in schema version 1.

All coordinates are device pixels of the input images; divide by `--scale` for logical pixels.

### What counts as a change

- A pixel changes when its YIQ colour distance from the other image's pixel passes `threshold` in `src/diff/yiq.zig`. The anti-aliasing test uses neighbours in the full images. On aligned moved rows, small balanced changes to coverage between shared colours are ignored when they fit the pixel's local edge contrast.
- Changed pixels join through edge or corner contact. Small groups count together toward `min_region_pixels` only across the tighter `evidence_gap` in `src/diff/regions.zig`. Faint specks and intermediate edge shades on stationary rows need edge-connected support before corners are joined. When either input fits within `single_pixel_area`, a single changed pixel can form a region.
- Groups merge when their gap is within the logical-pixel `merge_gap` in `src/diff/regions.zig`. Insertions, removals, and two-sided edits use a tighter gap when they meet. The merge gap doubles until the count fits `max_regions` in the same file.
- Each box uses the logical-pixel `padding` in `src/diff/regions.zig`. Edges round outward to whole device pixels and are clipped to the image.
- Rows are aligned by content, so an insertion or a deletion that moves the rows below it reports only the inserted or deleted rows. In two captures of the same height (a fixed viewport), a leading shift within `scroll_shift` (`src/diff.zig`) is treated as scroll. A larger leading shift is reported as content added or removed there. Content revealed at the bottom is reported as inserted. Content pushed below the viewport or behind a fixed footer is ignored. When stationary gutters divide the changed columns, the columns can align independently. For different capture heights, gutters are found over the shared rows. Columns with new content in the extension are still compared. The alignment searches up to `max_edits` (`src/diff/rows.zig`) row insertions plus deletions; past that, as for a tall pair of unrelated screenshots, rows are compared by position, which keeps the worst case fast.

### Limits and memory

Inputs are bounded by `max_pixels`, `max_extent`, and `max_encoded_bytes` in `src/value/image.zig`. The default per-image decode cap is `max_decode_bytes` in the same file. The PNG and JPEG budget accounts for the encoded bytes, block-rounded dimensions, sample depth, and workspace in `src/codec/stb.zig`. WebP charges its RGBA output and decoder allocations against the cap. Over-limit images fail with `ImageTooLarge`.

Noninterlaced RGBA8 PNGs use a fixed DEFLATE dictionary and one scanline of decode scratch each. The CLI can overlap two bounded PNG decodes. The comparison holds both decoded images, and the optional sheet is encoded one row at a time. Run `zig build bench` to measure peak RSS on the fixture pairs or your own captures.

## Library

Add the package to `build.zig.zon` with `zig fetch --save <release tarball URL>`, then import its module:

```zig
// build.zig
const uidiff = b.dependency("uidiff", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("uidiff", uidiff.module("uidiff"));
```

```zig
const std = @import("std");
const uidiff = @import("uidiff");

/// Compares two captures and writes the JSON report.
fn report(io: std.Io, gpa: std.mem.Allocator, out: *std.Io.Writer) !void {
    var diagnostics: uidiff.Diagnostics = .{};
    const result = try uidiff.compareFiles(io, gpa, .{ .before = "before.png", .after = "after.png" }, .{ .scale = 2 }, &diagnostics);
    defer result.deinit(gpa);
    try uidiff.report.write(gpa, out, result.regions, result.canvas(), result.moves);
}
```

`uidiff.decode` and `uidiff.compare` work on bytes and borrowed RGBA8 pixels. `uidiff.encodeComparisonSheet` streams the styled PNG to a writer. `uidiff.renderComparisonSheet` takes the comparison's regions and moves and returns the styled sheet in memory. `Options.scale` takes a `uidiff.Scale` in device pixels per CSS pixel. `Options.max_decode_bytes` lets `compareFiles` apply a lower per-image decode cap. On failure, `diagnostics.path` names the file concerned.

## Development

Run the [repository gates](AGENTS.md#gates) before submitting a contribution. `zig build fixtures` regenerates the synthetic PNG, JPEG, and WebP pairs in `tests/fixtures/images`. The test gate checks that the committed fixtures are current.

Run `zig build bench` to measure the bundled synthetic phone and desktop pairs: decode, compare, the `--annotate` sheet, the file pipeline and peak RSS. Run `zig build bench -Dbench-before=before.jpg -Dbench-after=after.jpg` to measure your own pair, adding `-Dbench-scale=2` for its device scale (the CLI's default otherwise).

`zig build size` checks the CLI binary against its size budget in `build.zig`. See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## License

MIT. uidiff includes libwebp (BSD 3-Clause), zlib-ng (Zlib), stb_image (MIT or public domain) and code adapted from pixelmatch (ISC). Release archives include [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) beside `LICENSE`.

The annotated sheet embeds bitmap glyphs derived from IBM Plex Sans. The glyphs are not distributed as a font named Plex. The full OFL-1.1 text is in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES). Run `python3 scripts/generate-font.py --check` to verify the [committed table](src/annotate/font-ascii.bin) offline. Use `--verify-generated` for a fresh rasterization with the pinned generator dependencies.
