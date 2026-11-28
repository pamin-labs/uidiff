# Repository Instructions

uidiff aligns screenshot content that only moved and boxes real changes. It emits numbered regions as JSON. It is MIT-licensed and open source; contributions follow [CONTRIBUTING.md](CONTRIBUTING.md).

Follow the public pamin-labs/skills engineering rules in [core](.agents/skills/pamin-engineering/references/core.md), [Zig](.agents/skills/pamin-engineering/references/zig.md), and [performance](.agents/skills/pamin-engineering/references/performance.md).

## Rules

- Prioritize performance, then memory, CPU, and disk use. Size buffers once from the image, keep allocations out of pixel and row loops, and use SIMD on the pixel kernel. Report before and after measurements and the `zig build bench` method for performance claims.
- Keep runtime safety enabled throughout uidiff. The source gate enforces this in `src/`. The build accepts Debug and ReleaseSafe for Zig code.
- Write uidiff code in Zig. A C file is reserved for a C library implementation unit or an ABI operation that Zig cannot supply. Each such file documents why it exists.
- Use the Zig version and dependency hashes pinned in `build.zig.zon`. Upgrade the toolchain separately.
- The tests in `tests/` and beside the code are the specification. A behaviour change updates them in the same change.
- Logs and errors name files and counts only.
- Write changes in English and use scoped Conventional Commits.
- A release archive ships `LICENSE` and `THIRD_PARTY_NOTICES` beside the binary. The notices cover the PNG, JPEG and WebP decoder dependencies and the embedded IBM Plex Sans bitmap glyphs.
- **Exception to core's "Commits and PRs" section:** this repository takes contributions through the open-source flow in [CONTRIBUTING.md](CONTRIBUTING.md); where core's section asks for more, CONTRIBUTING.md wins.
- **Exception to core's text and locales rule:** the CLI's usage text and error lines are English only, as developer tools' usually are. Machine output is the versioned JSON report and stable error names: the library's error set (`ImageTooLarge`, `InvalidScale`), which the CLI prints after a file's path and `--batch` writes in a failed line's `error` field. A single run refuses a bad `--scale` value as a usage error, never as `InvalidScale`. Callers that show text to end users localize from those.

## Layout

Zig source files use snake_case identifiers as basenames. `tests/source/order.zig` checks that a direct Zig file import binds to its basename without `.zig`. Named build modules and declarations selected from an import keep their own names.

- `build.zig` names the build steps and wires the products and checks. `build/codecs.zig` compiles, patches and translates the vendored C libraries.
- `src/root.zig` exposes the public library. It imports only module roots, the files beside each layer directory.
- `src/testing.zig` is the private `uidiff_testing` module created for repository test runners. It exposes procedural RGBA canvases and painters, assertions over public comparison results, and bounded RGBA inputs for fuzzing.
- `src/value.zig` and `src/value/` hold shared values and the image and memory bounds. Value modules depend only on other values and the standard library. Packed pixel SIMD lanes are owned by `src/value/image.zig`.
- `src/codec.zig` and `src/codec/` handle format detection, bounded file reads, dimension and memory-budget checks, decoding and PNG encoding. `src/codec/types.zig` holds the shared decoder header type, and `src/codec/memory.zig` and `src/codec/memory.h` hold the C allocation hooks. Only `src/codec/png/stb.zig` imports the translated stb_image header, only `src/codec/jpeg.zig` the translated libjpeg-turbo bridge under `src/codec/jpeg/`, and only `src/codec/webp.zig` the translated libwebp decoder header; the encoder headers are translated separately for the fixture generator, so the shipped library never includes them. `src/codec/png.zig` exposes PNG registration, decoding and encoding through the bounded streams in `src/codec/png/`. The PNG byte vector widths live in `src/codec/png/simd.zig`. `src/codec/png/streams.zig` writes the PNG decoder tests' synthetic streams; only test declarations import it.
- `src/diff.zig` owns the comparison API and resolves collected regions. The comparison internals in `src/diff/` are named, with their tiers, under Layers. `src/diff/rows/recolour.zig` identifies runs of changed colour within aligned bands. `src/annotate.zig` and `src/annotate/` number and place labels and draw the annotated sheet. `src/annotate/crops.zig` owns close-up geometry and sampling, and `src/annotate/sheet.zig` composes the overview and the detail rows. `src/report.zig` owns the versioned JSON report.
- `src/annotate/sheet/` plans the overview, ribbons and details for the row compositor in `src/annotate/sheet.zig`.
- `src/annotate/drawing/` owns row painting, sheet copy, palette, bitmap text and the font atlas behind `src/annotate/drawing.zig`.
- `src/annotate/badges/` owns badge placement, routing and painting behind `src/annotate/badges.zig`.
- `src/pipeline.zig` is the file pipeline: it checks the options once, decodes both files, compares them and writes the sheet atomically. The CLI calls it and only translates.
- `src/cli.zig` is the CLI entry and `src/cli/` its argument syntax and usage text (`src/cli/args.zig`), exit statuses (`src/cli/status.zig`), the `--batch` request loop (`src/cli/batch.zig`), the batch's block-reusing allocator (`src/cli/reuse.zig`) and the CLI's huge-page allocator (`src/cli/pages.zig`).
- `bench/` measures the public API. `tools/fixtures/` generates the committed fixtures and `tools/size.zig` checks the CLI binary size.
- `npm/` contains the JavaScript launcher. The release tooling stages its manifest and the scoped launcher and its native platform packages from the build version and target list.
- `skills/uidiff/` documents screenshot capture, comparison and report interpretation for agents.
- `scripts/` contains developer tooling. `scripts/release/` packages the CLI, renders the Homebrew formula and tests the launcher and installers. The installers are `install.sh` and `install.ps1` at the repository root.
- `.github/` contains the release target list and workflows. Dispatch `release.yml` from `main` with a `version` input. The workflow commits that version to `build.zig.zon`, builds the ReleaseSafe matrix shared with CI, creates the tagged GitHub release, mirrors assets to R2 and publishes npm packages through OIDC with provenance. Stable releases also update the Homebrew tap from the published formula asset.
- `tests/compare.zig` registers the comparison scenarios in `tests/compare/`, and `tests/sheet.zig` registers the annotated sheet scenarios in `tests/sheet/`. Both use the public `uidiff` module and the private `uidiff_testing` module. `tests/` runs the installed CLI (`tests/e2e.zig`), decodes the fixtures through the public API (`tests/decode.zig`), and checks source layout, layering and declaration order in `tests/source/`. It also runs the generator and size checker unit tests. `tests/fuzz/` holds one fuzz target per top-level file, each its own test binary. `tests/fixtures.zig` is the fixture set's root; `tests/fixtures/` holds fixture metadata, the freshness check and the generated images with expected reports. A unit test sits at the end of the file whose code it exercises. A comparison or sheet scenario lives in its area under `tests/compare/` or `tests/sheet/`. Shared test helpers live in `src/testing/`, with committed fixture metadata and sample reads owned by `tests/fixtures.zig`. Private fuzz targets sit beside the code they exercise, including the CLI target over arguments and batch request lines (one per test binary, since the fuzzer runs only one), and public API fuzz targets live in `tests/fuzz/`.

## Layers

`tests/source/layers.zig` reads the tables in this section. A file imports files of its own layer, except that a file inside a layer's directory never imports the layer's root; it imports another layer only through that layer's root, the first file its row names, and only if its row lists that layer. `std` and `builtin` are always allowed.

| Layer | Paths | May import |
| --- | --- | --- |
| value | `src/value.zig` `src/value/` | |
| codec | `src/codec.zig` `src/codec/` | value |
| diff | `src/diff.zig` `src/diff/` | value |
| annotate | `src/annotate.zig` `src/annotate/` | value |
| report | `src/report.zig` | value |
| pipeline | `src/pipeline.zig` | value, codec, diff, annotate |
| testing | `src/testing.zig` `src/testing/` | uidiff |
| api | `src/root.zig` | value, codec, diff, annotate, report, pipeline |
| cli | `src/cli.zig` `src/cli/` | `uidiff` |
| build | `build/` | value |
| test | `tests/` | `uidiff` |
| tool | `bench/` `tools/` | `uidiff` |

`src/testing/jpeg.zig` belongs to `uidiff` and is path-imported by test declarations in `src/codec/jpeg.zig` and `src/pipeline.zig`, `src/testing/canvas.zig` is `uidiff_test_canvas`, and the remaining files in `src/testing/` belong to `uidiff_testing`. Scenario runners and fuzz targets use procedural images and fuzz inputs from `uidiff_testing`. The named `fixtures` module describes the committed fixture set. Source unit tests and the private testing module share the named `uidiff_test_canvas` leaf because Zig assigns each source file to one module per compilation.

Named build modules, and the only files that may import them. The `export` row names the files whose exported functions C code calls back.

| Module | Importers |
| --- | --- |
| `png_format` | `src/codec/png.zig` `src/codec/png/` `tests/e2e.zig` `tests/decode.zig` `tools/fixtures/generate.zig` |
| `stb_c` | `src/codec/png/stb.zig` |
| `jpeg_encode_c` | `tools/fixtures/jpeg_generate.zig` |
| `jpeg_c` | `src/codec/jpeg.zig` |
| `webp_c` | `src/codec/webp.zig` |
| `zlib_c` | `src/codec/png/zlib.zig` |
| `stb_write_c` | `tools/fixtures/encode.zig` |
| `webp_encode_c` | `tools/fixtures/encode.zig` |
| `codec_memory` | `src/codec.zig` `src/codec/png/zlib.zig` `src/codec/png/scanlines.zig` `src/codec/png/stb.zig` `src/codec/jpeg.zig` `src/codec/webp.zig` `tools/fixtures/encode.zig` |
| `uidiff_test_canvas` | `src/testing.zig` `src/testing/expect.zig` `src/diff.zig` `src/diff/` `src/annotate/sheet/plan.zig` |
| `uidiff_testing` | `tests/compare/` `tests/sheet/` `tests/decode.zig` `tests/e2e.zig` `tests/fuzz/` |
| `fixtures` | `tests/e2e.zig` `tests/decode.zig` `tests/fuzz/` |
| `e2e_options` | `tests/e2e.zig` |
| `cli_options` | `src/cli.zig` |
| `fixture_cases` | `tools/fixtures/generate.zig` `tools/fixtures/encode.zig` |
| `fixture_jpeg` | `tools/fixtures/jpeg_generate.zig` |
| `fixture_options` | `tests/fixtures/fresh.zig` |
| `required_test_options` | `src/root.zig` |
| `export` | `src/codec/memory.zig` |

Only a submodule's facade and implementation files may import its implementation directory. Implementation files cannot import their own facade.

| Submodule root | Implementation directory |
| --- | --- |
| `src/diff/regions.zig` | `src/diff/regions/` |
| `src/diff/rows.zig` | `src/diff/rows/` |
| `src/annotate/badges.zig` | `src/annotate/badges/` |
| `src/annotate/sheet.zig` | `src/annotate/sheet/` |
| `src/annotate/drawing.zig` | `src/annotate/drawing/` |
| `src/codec/png.zig` | `src/codec/png/` |
| `src/codec/jpeg.zig` | `src/codec/jpeg/` |
| `tests/compare.zig` | `tests/compare/` |
| `tests/sheet.zig` | `tests/sheet/` |

The diff and annotate internals use tiers. Within a layer, a unit imports another only if that unit's tier is lower. Files inside one unit import each other under the rules above. `src/diff.zig` and `src/annotate.zig` sit above their layers' tiers. Every Zig file under `src/diff/` and `src/annotate/` belongs to a unit in the table.

| Tier | Paths | Holds |
| --- | --- | --- |
| 4 | `src/diff/span.zig` | Aligns the changed span, walks its bands and owns their scratch buffers |
| 3 | `src/diff/motion.zig` | Gathers moves supported by alignment |
| 3 | `src/diff/unpaired.zig` | Compares rows aligned to a gap |
| 2 | `src/diff/rows.zig` `src/diff/rows/` | Row hashing, the band search, chrome detection and refinement |
| 2 | `src/diff/regions.zig` `src/diff/regions/` | Grouping, visible edit rules, retained moves and final ordering |
| 1 | `src/diff/columns.zig` | Column analysis, card search and the compared scope |
| 1 | `src/diff/yiq.zig` | YIQ colour distance, antialiasing and writing the change mask |
| 0 | `src/diff/mask.zig` | Change mask cells, band scratch and byte search |
| 0 | `src/diff/pixel.zig` | Pixel and block equality kernels |
| 5 | `src/annotate/sheet.zig` `src/annotate/sheet/` | Sheet planning and row composition |
| 4 | `src/annotate/badges.zig` `src/annotate/badges/` | Badge placement, routing and painting |
| 4 | `src/annotate/ribbons.zig` | Gutter ribbons for aligned rows |
| 3 | `src/annotate/focus.zig` | Groups nearby panoramic details into focus windows |
| 2 | `src/annotate/crops.zig` | Source windows and sampling |
| 1 | `src/annotate/drawing.zig` `src/annotate/drawing/` | Row painting, text, copy and palette |
| 0 | `src/annotate/geometry.zig` | Source and sheet rectangles, pane arrangement and previews |

## Decoders

The noninterlaced 8-bit RGB, RGBA, grayscale and indexed PNG path uses zlib-ng to inflate scanlines. Grayscale and indexed rows unfilter in one-byte samples before expansion to RGBA. Indexed images support PLTE and palette tRNS. Grayscale colour keys, unusual palettes and out-of-range indices fall back to stb_image. The PNG writer streams through zlib-ng at level 2. stb_image decodes other PNG profiles. Both PNG paths preserve tolerance for CRC and Adler checksum values. libjpeg-turbo decodes 8-bit JPEG with the accurate integer IDCT and fancy chroma upsampling. Its Arm64 build uses C NEON intrinsics. libwebp decodes WebP. The shipped binary builds C decoders for size; tests and fuzzing compile them inside the Zig module, in its mode, so UBSan traps undefined behaviour in Debug and safe builds. Under `zig build test --fuzz` vendored C runs on fuzzed input without coverage feedback: Zig 0.17's fuzzer cannot read clang's coverage tables, so `fuzz_coverage_flags` in `build/codecs.zig` turns clang's instrumentation off, and only the Zig code steers the fuzzer. The shared allocation hooks in `src/codec/memory.zig` charge each decode against its budget. stb's PNG budget is sized from the header. JPEG and WebP charge their decoded buffers and scratch allocations against the caller's cap. The file pipeline uses at most one decode worker per comparison for all formats. Both decoders keep their own state and budget. The caller joins the worker and reports a before-side failure first.

`zig build jpeg-fixtures` regenerates the JPEG profiles with the pinned scalar encoder. The test gate verifies both the encoded fixtures and their decoded pixel hashes.

PNG chunk checksums use zlib-ng's CRC-32. On x86_64, zlib-ng detects PCLMULQDQ at runtime and uses its braid kernel as a fallback. Chorba is disabled. On Arm64, zlib-ng uses ARMv8 CRC instructions when the target or runtime CPU supports them. The zlib stream uses Adler-32.

## Interval glossary

- A column interval starts at x (called left in a column span) and has a width. A row interval starts at y and has a height. The intervals are half-open, so right is x + width and bottom is y + height. The column card search keeps a left bound and exclusive right bound in `Edge` to use directly as loop endpoints.
- An aligned band stores a row start and row count for each side. The flood fill's `InclusiveSpan` uses inclusive first and last indices on either axis.
- A byte span in the PNG decoder stores its start offset and length.

## Annotation glossary

- Focus is a source window in a panoramic sheet. It may cover several nearby changes.
- Detail is the sheet row for one numbered region.
- Crop maps a source rectangle to its destination rectangle on the sheet.
- Zoom is the sampling scale used to construct a crop.
- Close-up is the reader-facing name for the paired crops of a detail. The sheet introduces them with “Changes up close”.

## Gates

- `zig fmt --check .`
- `zig build test`
- `zig build e2e`
- `zig build test-threaded` on Linux
- `zig build test-png-rows` and `zig build test-x86-fallback` on the CI architectures
- `bash scripts/fuzz.sh` (the inline CLI and PNG targets and each target in `tests/fuzz/`)
- `zig build bench`
- `zig build size`
- `python3 scripts/readme-images.py check` and `python3 scripts/test-readme-images.py` (validate local README image links)
- `python3 scripts/generate-font.py --check` (offline, checked against the pinned atlas digest)
- `zig build -Doptimize=safe` and `zig build test` from an empty dependency and global cache
- `zig build install size -Doptimize=safe -Dtarget=<target>` for each target in `.github/release-targets.json`
- After building the CLI, run `python3 -B scripts/release/test_launcher.py` to check both standalone installers against the packager and exercise the staged npm launcher. Run the offline installer test for your platform, `sh scripts/release/test_install.sh` or `pwsh -File scripts/release/test_install.ps1`.
- `python3 -B scripts/release/test_source_package.py` after the release build to compile the files published by the Zig source package.
- Run `actionlint` and `shellcheck install.sh scripts/release/test_install.sh` for release changes. Before the first automated npm release, each npm package needs a trusted publisher for `release.yml`.

`zig build test` fails when the committed fixtures differ from a fresh generation. `zig build fixtures` regenerates them on the host. `zig build fixture-generator -Dtarget=<target>` builds the generator for a target without running it.

Run `python3 scripts/binary_sections.py <binary>` to record file bytes and code and data section sizes for a release build.
