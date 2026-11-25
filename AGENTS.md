# Repository Instructions

uidiff aligns screenshot content that only moved and boxes real changes. It emits numbered regions as JSON. It is MIT-licensed and open source; contributions follow [CONTRIBUTING.md](CONTRIBUTING.md).

Follow the public pamin-labs/skills engineering rules in [core](.agents/skills/pamin-engineering/references/core.md), [Zig](.agents/skills/pamin-engineering/references/zig.md), and [performance](.agents/skills/pamin-engineering/references/performance.md).

## Rules

- Prioritize performance, then memory, CPU, and disk use. Size buffers once from the image, keep allocations out of pixel and row loops, and use SIMD on the pixel kernel. Report before and after measurements and the `zig build bench` method for performance claims.
- Write uidiff code in Zig. A C file is reserved for a C library implementation unit or an ABI operation that Zig cannot supply. Each such file documents why it exists.
- Use the Zig version and dependency hashes pinned in `build.zig.zon`. Upgrade the toolchain separately.
- The tests in `tests/` and beside the code are the specification. A behaviour change updates them in the same change.
- Logs and errors name files and counts only.
- Write changes in English and use scoped Conventional Commits.
- A release archive ships `LICENSE` and `THIRD_PARTY_NOTICES` beside the binary. The notices cover the PNG, JPEG and WebP decoder dependencies and the embedded IBM Plex Sans bitmap glyphs.
- **Exception to core's "Commits and PRs" section:** this repository takes contributions through the open-source flow in [CONTRIBUTING.md](CONTRIBUTING.md); where core's section asks for more, CONTRIBUTING.md wins.
- **Exception to core's text and locales rule:** the CLI's usage text and error lines are English only, as developer tools' usually are. Machine output is the versioned JSON report and stable error names (`ImageTooLarge`, `InvalidScale`); callers that show text to end users localize from those.

## Layout

- `src/root.zig` exposes the public library. It imports only module roots: the files beside each layer directory.
- `src/value.zig` and `src/value/` hold shared values and the image and memory bounds. Value modules depend only on other values and the standard library.
- `src/codec.zig` and `src/codec/` handle format detection, bounded file reads, dimension and memory-budget checks, decoding and PNG encoding. Only `src/codec/stb.zig` imports the translated stb_image header, only `src/codec/jpeg.zig` the translated libjpeg-turbo bridge, and only `src/codec/webp.zig` the translated libwebp decoder header; the encoder headers are translated separately for the fixture generator, so the shipped library never includes them.
- `src/diff.zig` and `src/diff/` compare pixels, align rows, and produce regions. `src/annotate.zig` and `src/annotate/` number and place labels and draw the annotated sheet. `src/report.zig` owns the versioned JSON report.
- `src/files.zig` is the file pipeline: it checks the options once, decodes both files, compares them and writes the sheet atomically. The CLI calls it and only translates.
- `src/cli.zig` is the CLI entry and `src/cli/` its argument syntax and usage text.
- `bench/` measures the public API.
- `tests/` runs the installed CLI (`tests/e2e.zig`), decodes the fixtures through the public API (`tests/decode.zig`), checks the binary size budget, and checks source layout, layering and declaration order. `tests/fuzz/` holds one fuzz target per file, each its own test binary. `tests/fixtures.zig` is the fixture set's root; `tests/fixtures/` holds the synthetic fixture generator, its encoders, the freshness check and the generated images with expected reports. Unit tests live beside the code they exercise.

## Layers

`tests/layers.zig` reads these two tables. A file imports files of its own layer, except that a file inside a layer's directory never imports the layer's root; it imports another layer only through that layer's root, the first file its row names, and only if its row lists that layer. `std` and `builtin` are always allowed.

| Layer | Paths | May import |
| --- | --- | --- |
| value | `src/value.zig` `src/value/` | |
| codec | `src/codec.zig` `src/codec/` | value |
| diff | `src/diff.zig` `src/diff/` | value |
| annotate | `src/annotate.zig` `src/annotate/` | value |
| report | `src/report.zig` | value |
| files | `src/files.zig` | value, codec, diff, annotate |
| api | `src/root.zig` | value, codec, diff, annotate, report, files |
| cli | `src/cli.zig` `src/cli/` | `uidiff` |
| tool | `bench/` `tests/` | `uidiff` |

Named build modules, and the only files that may import them. The `export` row names the files whose exported functions C code calls back.

| Module | Importers |
| --- | --- |
| `stb_c` | `src/codec/stb.zig` |
| `jpeg_encode_c` | `tests/fixtures/jpeg_generate.zig` |
| `jpeg_c` | `src/codec/jpeg.zig` |
| `webp_c` | `src/codec/webp.zig` |
| `zlib_c` | `src/codec/png.zig` `src/codec/png_scanlines.zig` |
| `stb_write_c` | `tests/fixtures/encode.zig` |
| `webp_encode_c` | `tests/fixtures/encode.zig` |
| `codec_memory` | `src/codec.zig` `src/codec/png_scanlines.zig` `src/codec/stb.zig` `src/codec/jpeg.zig` `src/codec/webp.zig` `tests/fixtures/encode.zig` |
| `fixtures` | `tests/e2e.zig` `tests/decode.zig` `tests/fuzz/` |
| `e2e_options` | `tests/e2e.zig` |
| `fixture_options` | `tests/fixtures/fresh.zig` |
| `required_test_options` | `src/root.zig` |
| `export` | `src/codec/memory.zig` |

## Decoders

The noninterlaced RGB8 and RGBA8 PNG path uses zlib-ng to inflate scanlines into the output image. The PNG writer streams through zlib-ng at level 4. stb_image decodes other PNG profiles. Both PNG paths preserve tolerance for CRC and Adler checksum values. libjpeg-turbo decodes 8-bit JPEG with the accurate integer IDCT and fancy chroma upsampling. Its Arm64 build uses C NEON intrinsics. libwebp decodes WebP. The shipped binary builds C decoders for size; tests and fuzzing compile them inside the Zig module, in its mode, so UBSan traps undefined behaviour in Debug and safe builds. Under `zig build test --fuzz` vendored C runs on fuzzed input without coverage feedback: Zig 0.17's fuzzer cannot read clang's coverage tables, so `fuzz_coverage_flags` in `build.zig` turns clang's instrumentation off, and only the Zig code steers the fuzzer. The shared allocation hooks in `src/codec/memory.zig` charge each decode against its budget. stb's PNG budget is sized from the header. JPEG and WebP charge their decoded buffers and scratch allocations against the caller's cap.

`zig build jpeg-fixtures` regenerates the JPEG profiles with the pinned scalar encoder. The test gate verifies both the encoded fixtures and their decoded pixel hashes.

## Gates

- `zig fmt --check .`
- `zig build test`
- `zig build e2e`
- `zig build test-threaded` on Linux
- `zig build test-png-rows` and `zig build test-x86-fallback` on the CI architectures
- `bash scripts/fuzz.sh` (every fuzz target: the CLI's argument parser and each file in `tests/fuzz/`)
- `zig build bench`
- `zig build size`
- `python3 scripts/generate-font.py --check` (offline, checked against the pinned atlas digest)
- `zig build -Doptimize=safe` and `zig build test` from an empty dependency and global cache
- `zig build -Doptimize=safe -Dtarget=<target>` for each target in `.github/workflows/ci.yml`

`zig build test` fails when the committed fixtures differ from a fresh generation. `zig build fixtures` regenerates them on the host. `zig build fixture-generator -Dtarget=<target>` builds the generator for a target without running it.

Run `python3 scripts/binary_sections.py <binary>` to record file bytes and code and data section sizes for a release build.
