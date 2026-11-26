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
- **Exception to core's text and locales rule:** the CLI's usage text and error lines are English only, as developer tools' usually are. Machine output is the versioned JSON report and stable error names (`ImageTooLarge`, `InvalidScale`); callers that show text to end users localize from those.

## Layout

- `src/root.zig` exposes the public library. It imports only module roots, the files beside each layer directory.
- `src/testing.zig` is the private `uidiff_testing` module created for repository test runners. It exposes procedural RGBA canvases and painters, assertions over public comparison results, and bounded RGBA inputs for fuzzing.
- `src/value.zig` and `src/value/` hold shared values and the image and memory bounds. Value modules depend only on other values and the standard library.
- `src/codec.zig` and `src/codec/` handle format detection, bounded file reads, dimension and memory-budget checks, decoding and PNG encoding. `src/codec/types.zig` holds the shared decoder header type. Only `src/codec/png/stb.zig` imports the translated stb_image header, only `src/codec/jpeg.zig` the translated libjpeg-turbo bridge under `src/codec/jpeg/`, and only `src/codec/webp.zig` the translated libwebp decoder header; the encoder headers are translated separately for the fixture generator, so the shipped library never includes them. `src/codec/png.zig` exposes PNG registration, decoding and encoding through the bounded streams in `src/codec/png/`.
- `src/diff.zig` owns the comparison API and resolves collected regions. The comparison internals in `src/diff/` are named, with their tiers, under Layers. `src/annotate.zig` and `src/annotate/` number and place labels and draw the annotated sheet. `src/annotate/badges.zig` places badges and exposes the routing and painting in `src/annotate/badges/`. `src/annotate/crops.zig` owns close-up geometry and sampling, and `src/annotate/report_sheet.zig` composes the overview and the detail rows. `src/report.zig` owns the versioned JSON report.
- `src/files.zig` is the file pipeline: it checks the options once, decodes both files, compares them and writes the sheet atomically. The CLI calls it and only translates.
- `src/cli.zig` is the CLI entry and `src/cli/` its argument syntax and usage text.
- `bench/` measures the public API.
- `npm/` contains the JavaScript launcher. The release tooling stages its manifest and the scoped launcher and its native platform packages from the build version and target list.
- `skills/uidiff/` documents screenshot capture, comparison and report interpretation for agents.
- `scripts/` contains developer tooling. `scripts/release/` packages the CLI, renders the Homebrew formula and tests the launcher and installers. The installers are `install.sh` and `install.ps1` at the repository root.
- `.github/` contains the release target list and workflows. Dispatch `release.yml` from `main` with a `version` input. The workflow commits that version to `build.zig.zon`, builds the ReleaseSafe matrix shared with CI, creates the tagged GitHub release, mirrors assets to R2 and publishes npm packages through OIDC with provenance. Stable releases also update the Homebrew tap from the published formula asset.
- `tests/compare.zig` registers the comparison scenarios in `tests/compare/`, and `tests/sheet.zig` registers the annotated sheet scenarios in `tests/sheet/`. Both use the public `uidiff` module and the private `uidiff_testing` module. `tests/` runs the installed CLI (`tests/e2e.zig`), decodes the fixtures through the public API (`tests/decode.zig`), checks the binary size budget, and checks source layout, layering and declaration order. `tests/fuzz/` holds one fuzz target per top-level file, each its own test binary. `tests/fixtures.zig` is the fixture set's root; `tests/fixtures/` holds the synthetic fixture generator, its encoders, the freshness check and the generated images with expected reports. A unit test sits at the end of the file whose code it exercises. A comparison or sheet scenario lives in its area under `tests/compare/` or `tests/sheet/`. Shared test helpers live in `src/testing/`, with committed fixture metadata and sample reads owned by `tests/fixtures.zig`. Private fuzz targets sit beside the code they exercise, including the CLI arguments target, and public API fuzz targets live in `tests/fuzz/`.

## Layers

`tests/layers.zig` reads the tables in this section. A file imports files of its own layer, except that a file inside a layer's directory never imports the layer's root; it imports another layer only through that layer's root, the first file its row names, and only if its row lists that layer. `std` and `builtin` are always allowed.

| Layer | Paths | May import |
| --- | --- | --- |
| value | `src/value.zig` `src/value/` | |
| codec | `src/codec.zig` `src/codec/` | value |
| diff | `src/diff.zig` `src/diff/` | value |
| annotate | `src/annotate.zig` `src/annotate/` | value |
| report | `src/report.zig` | value |
| files | `src/files.zig` | value, codec, diff, annotate |
| testing | `src/testing.zig` `src/testing/` | uidiff |
| api | `src/root.zig` | value, codec, diff, annotate, report, files |
| cli | `src/cli.zig` `src/cli/` | `uidiff` |
| tool | `bench/` `tests/` | `uidiff` |

`src/testing/jpeg.zig` belongs to `uidiff` and is path-imported by test declarations in `src/codec/jpeg.zig` and `src/files.zig`, `src/testing/canvas.zig` is `uidiff_test_canvas`, and the remaining files in `src/testing/` belong to `uidiff_testing`. Scenario runners and fuzz targets import fixtures by the named `uidiff_testing` module. Source unit tests and the private testing module share the named `uidiff_test_canvas` leaf because Zig assigns each source file to one module per compilation.

Named build modules, and the only files that may import them. The `export` row names the files whose exported functions C code calls back.

| Module | Importers |
| --- | --- |
| `stb_c` | `src/codec/png/stb.zig` |
| `jpeg_encode_c` | `tests/fixtures/jpeg_generate.zig` |
| `jpeg_c` | `src/codec/jpeg.zig` |
| `webp_c` | `src/codec/webp.zig` |
| `zlib_c` | `src/codec/png/zlib.zig` `src/codec/png/scanlines.zig` |
| `stb_write_c` | `tests/fixtures/encode.zig` |
| `webp_encode_c` | `tests/fixtures/encode.zig` |
| `codec_memory` | `src/codec.zig` `src/codec/png/zlib.zig` `src/codec/png/scanlines.zig` `src/codec/png/stb.zig` `src/codec/jpeg.zig` `src/codec/webp.zig` `tests/fixtures/encode.zig` |
| `uidiff_test_canvas` | `src/testing.zig` `src/testing/expect.zig` `src/diff.zig` `src/diff/` `src/annotate/report_layout.zig` |
| `uidiff_testing` | `tests/compare/` `tests/sheet/` `tests/decode.zig` `tests/e2e.zig` `tests/fuzz/` |
| `fixtures` | `tests/e2e.zig` `tests/decode.zig` `tests/fuzz/` |
| `e2e_options` | `tests/e2e.zig` |
| `cli_options` | `src/cli.zig` |
| `fixture_options` | `tests/fixtures/fresh.zig` |
| `required_test_options` | `src/root.zig` |
| `export` | `src/codec/memory.zig` |

Only a submodule's facade and implementation files may import its implementation directory. Implementation files cannot import their own facade.

| Submodule root | Implementation directory |
| --- | --- |
| `src/diff/regions.zig` | `src/diff/regions/` |
| `src/diff/rows.zig` | `src/diff/rows/` |
| `src/annotate/badges.zig` | `src/annotate/badges/` |
| `src/codec/png.zig` | `src/codec/png/` |
| `src/codec/jpeg.zig` | `src/codec/jpeg/` |
| `tests/compare.zig` | `tests/compare/` |
| `tests/sheet.zig` | `tests/sheet/` |

Each unit of the diff internals, with its tier. A unit imports another only if that unit's tier is lower; files inside one unit import each other under the rules above. `src/diff.zig` sits above every tier. A file under `src/diff/` that this table does not name fails the test.

| Diff tier | Paths | Holds |
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

## Decoders

The noninterlaced 8-bit RGB, RGBA, grayscale and indexed PNG path uses zlib-ng to inflate scanlines. Grayscale and indexed rows unfilter in one-byte samples before expansion to RGBA. Indexed images support PLTE and palette tRNS. Grayscale colour keys, unusual palettes and out-of-range indices fall back to stb_image. The PNG writer streams through zlib-ng at level 3. stb_image decodes other PNG profiles. Both PNG paths preserve tolerance for CRC and Adler checksum values. libjpeg-turbo decodes 8-bit JPEG with the accurate integer IDCT and fancy chroma upsampling. Its Arm64 build uses C NEON intrinsics. libwebp decodes WebP. The shipped binary builds C decoders for size; tests and fuzzing compile them inside the Zig module, in its mode, so UBSan traps undefined behaviour in Debug and safe builds. Under `zig build test --fuzz` vendored C runs on fuzzed input without coverage feedback: Zig 0.17's fuzzer cannot read clang's coverage tables, so `fuzz_coverage_flags` in `build.zig` turns clang's instrumentation off, and only the Zig code steers the fuzzer. The shared allocation hooks in `src/codec/memory.zig` charge each decode against its budget. stb's PNG budget is sized from the header. JPEG and WebP charge their decoded buffers and scratch allocations against the caller's cap. The file pipeline uses at most one decode worker per comparison for all formats. Both decoders keep their own state and budget. The caller joins the worker and reports a before-side failure first.

`zig build jpeg-fixtures` regenerates the JPEG profiles with the pinned scalar encoder. The test gate verifies both the encoded fixtures and their decoded pixel hashes.

PNG chunk checksums use zlib-ng's CRC-32. On x86_64, zlib-ng detects PCLMULQDQ at runtime and uses its braid kernel as a fallback. Chorba is disabled. On Arm64, zlib-ng uses ARMv8 CRC instructions when the target or runtime CPU supports them. The zlib stream uses Adler-32.

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
