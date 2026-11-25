//! Builds the CLI, codec bindings, tests, fixtures, benchmark and size check.
const std = @import("std");
const fixtures = @import("tests/fixtures.zig");
const values = @import("src/value.zig");
const Optimize = std.builtin.Optimize;
const Build = std.Build;

/// Translated decoder headers: only the codec bindings import these.
const Decoders = struct {
    jpeg: *Build.Module,
    stb: *Build.Module,
    webp: *Build.Module,
    zlib: *Build.Module,
    memory: *Build.Module,
};

/// How a build compiles the C decoders: in their own measured mode for the
/// shipped binary, or inside the Zig module, in its mode with UBSan, for
/// tests and fuzzing (without coverage feedback; see fuzz_coverage_flags).
const CodecBuild = enum { shipped, shipped_lto, checked };
const X86Simd = enum { shipped, baseline, without_ssse3, without_sse4, without_avx2, without_pclmul };

// The shipped Zig binary retains runtime safety checks. The C decoders
// run with UBSan in the checked test build and in fuzzing.
const shipped_mode: Optimize = .safe;
const codec_mode: Optimize = .fast;
const png_compression_level = 4;
/// The shipped CLI's size budget for every CI target. Run zig build size
/// with -Dtarget to measure a specific binary.
const max_cli_bytes = 1_200_000;
const cli_name = "uidiff";
// The library unit test binary also fuzzes the streaming PNG decoder.
const library_fuzz_targets = 1;
const styled_sheet_fuzz_source = "tests/fuzz/sheet.zig";
/// Each fuzz target is its own test binary, so `zig build test --fuzz` runs every one.
const fuzz_targets = [_][]const u8{ "src/cli.zig", "tests/fuzz/decode.zig", "tests/fuzz/compare.zig", styled_sheet_fuzz_source };
/// Keeps clang's coverage instrumentation out of the C decoders under
/// `zig build test --fuzz`. Zig 0.17's fuzzer reads one PC per edge counter
/// from `__sancov_pcs1`, as its own backend writes them; clang writes two
/// words per edge to `__sancov_pcs` and calls comparison hooks the fuzzer
/// lacks, so instrumented C fails to link or aborts at start. The decoders are
/// still fuzzed, checked by UBSan, but without coverage feedback. Without
/// -ffuzz these flags change nothing.
const fuzz_coverage_flags = [_][]const u8{"-fno-sanitize-coverage=inline-8bit-counters,pc-table,trace-cmp"};
/// Lets the linker drop unused entry points from the C decoder objects.
const codec_section_flags = [_][]const u8{ "-ffunction-sections", "-fdata-sections" };
/// Tests that read source files outside the compiler's import graph.
const source_tests = [_][]const u8{ "tests/layers.zig", "tests/order.zig" };

const webp_common = [_][]const u8{
    "src/dsp/alpha_processing.c",
    "src/dsp/cpu.c",
    "src/dsp/dec.c",
    "src/dsp/dec_clip_tables.c",
    "src/dsp/filters.c",
    "src/dsp/lossless.c",
    "src/dsp/rescaler.c",
    "src/dsp/upsampling.c",
    "src/dsp/yuv.c",
    "src/utils/bit_reader_utils.c",
    "src/utils/color_cache_utils.c",
    "src/utils/filters_utils.c",
    "src/utils/huffman_utils.c",
    "src/utils/quant_levels_dec_utils.c",
    "src/utils/rescaler_utils.c",
    "src/utils/thread_utils.c",
    "src/utils/palette.c",
    "src/utils/random_utils.c",
};

const webp_decoder = [_][]const u8{
    "src/dec/alpha_dec.c",
    "src/dec/buffer_dec.c",
    "src/dec/frame_dec.c",
    "src/dec/io_dec.c",
    "src/dec/quant_dec.c",
    "src/dec/tree_dec.c",
    "src/dec/vp8_dec.c",
    "src/dec/vp8l_dec.c",
    "src/dec/webp_dec.c",
};

const webp_encoder = [_][]const u8{
    "src/enc/alpha_enc.c",
    "src/enc/analysis_enc.c",
    "src/enc/backward_references_cost_enc.c",
    "src/enc/backward_references_enc.c",
    "src/enc/config_enc.c",
    "src/enc/cost_enc.c",
    "src/enc/filter_enc.c",
    "src/enc/frame_enc.c",
    "src/enc/histogram_enc.c",
    "src/enc/iterator_enc.c",
    "src/enc/near_lossless_enc.c",
    "src/enc/picture_enc.c",
    "src/enc/picture_csp_enc.c",
    "src/enc/picture_psnr_enc.c",
    "src/enc/picture_rescale_enc.c",
    "src/enc/picture_tools_enc.c",
    "src/enc/predictor_enc.c",
    "src/enc/quant_enc.c",
    "src/enc/syntax_enc.c",
    "src/enc/token_enc.c",
    "src/enc/tree_enc.c",
    "src/enc/vp8l_enc.c",
    "src/enc/webp_enc.c",
    "src/dsp/cost.c",
    "src/dsp/enc.c",
    "src/dsp/lossless_enc.c",
    "src/dsp/ssim.c",
    "src/utils/bit_writer_utils.c",
    "src/utils/huffman_encode_utils.c",
    "src/utils/quant_levels_utils.c",
    "sharpyuv/sharpyuv.c",
    "sharpyuv/sharpyuv_cpu.c",
    "sharpyuv/sharpyuv_csp.c",
    "sharpyuv/sharpyuv_dsp.c",
    "sharpyuv/sharpyuv_gamma.c",
};

/// Configures the installed binary and verification steps.
pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const override = b.option(Optimize, "optimize", "Choose the CLI, benchmark and test optimization mode");
    const x86_simd = b.option(X86Simd, "x86-simd", "Choose a zlib-ng dispatch configuration for x86-64 benchmarks") orelse .shipped;
    if (x86_simd != .shipped and target.result.cpu.arch != .x86_64) @panic("-Dx86-simd requires an x86_64 target");
    const release: ?Optimize = switch (b.graph.release_mode) {
        .off => null,
        .any => shipped_mode,
        .safe => .safe,
        .fast => .fast,
        .small => .small,
    };
    const optimize = override orelse release orelse shipped_mode;
    const test_mode = override orelse release orelse .debug;
    const decoders = addDecoders(b, target);
    const lib = libraryOptions(b, target, optimize, decoders);
    const uidiff = b.addModule("uidiff", lib);
    linkShippedCodecs(b, uidiff, target, x86_simd, false);
    // Enable LTO for the measured Linux musl release targets. Windows opts in for benchmarking.
    const os = target.result.os.tag;
    const arch = target.result.cpu.arch;
    const linux_musl = os == .linux and target.result.abi == .musl;
    const can_lto = optimize == shipped_mode and (linux_musl or os == .windows) and
        (arch == .aarch64 or arch == .x86_64);
    const requested_lto = b.option(bool, "cli-lto", "Override LTO for Linux musl or Windows ReleaseSafe CLIs");
    if (requested_lto == true and !can_lto) @panic("-Dcli-lto=true requires an arm64 or x86-64 Linux musl or Windows ReleaseSafe target");
    // Keep bitcode archives out of the public module consumed by other builds.
    const use_lto = requested_lto orelse (can_lto and linux_musl);
    const cli_library = if (use_lto) b.createModule(lib) else uidiff;
    if (use_lto) linkShippedCodecs(b, cli_library, target, x86_simd, true);

    const cli = b.addExecutable(.{
        .name = cli_name,
        .use_lld = if (use_lto) true else null,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .debug,
            // The stripped CLI emits message-only panics. Windows retains
            // the unwind metadata used by its exception machinery.
            .unwind_tables = if (optimize != .debug and target.result.os.tag != .windows) .none else null,
            .imports = &.{.{ .name = "uidiff", .module = cli_library }},
        }),
    });
    // Keep the Windows Zig and CRT objects native. LLD can still optimize the C archives.
    if (use_lto and linux_musl) cli.lto = .full;
    const install_cli = b.addInstallArtifact(cli, .{});
    b.getInstallStep().dependOn(&install_cli.step);
    inline for (.{ "LICENSE", "THIRD_PARTY_NOTICES" }) |notice| b.installFile(notice, "bin/" ++ notice);
    addSizeCheck(b, install_cli);
    const generator = fixtureGenerator(b, target, decoders);
    const host_generator = if (target.query.isNative()) generator else fixtureGenerator(b, b.graph.host, addDecoders(b, b.graph.host));
    addTests(b, target, test_mode, decoders, install_cli, host_generator, x86_simd);
    addThreadedTest(b, target, decoders);
    addBenchmark(b, target, optimize, uidiff);
    const fuzz_count = b.addWriteFiles().add("fuzz-target-count.txt", b.fmt("{d}\n", .{fuzz_targets.len + library_fuzz_targets}));
    const fuzz_count_install = b.addInstallFile(fuzz_count, "fuzz-target-count.txt");
    b.step("fuzz-target-count", "Write the number of fuzz targets including the CLI").dependOn(&fuzz_count_install.step);
    const fixture_build = b.step("fixture-generator", "Build the fixture generator for the selected target");
    fixture_build.dependOn(&generator.step);
}

/// The library module's options, without its C decoders.
fn libraryOptions(b: *Build, target: Build.ResolvedTarget, optimize: Optimize, decoders: Decoders) Build.Module.CreateOptions {
    return .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = b.allocator.dupe(Build.Module.Import, &.{
            .{ .name = "stb_c", .module = decoders.stb },
            .{ .name = "jpeg_c", .module = decoders.jpeg },
            .{ .name = "webp_c", .module = decoders.webp },
            .{ .name = "zlib_c", .module = decoders.zlib },
            .{ .name = "codec_memory", .module = decoders.memory },
        }) catch @panic("OOM"),
    };
}

fn addCheckedLibrary(b: *Build, target: Build.ResolvedTarget, optimize: Optimize, decoders: Decoders, x86_simd: X86Simd) *Build.Module {
    const module = b.createModule(libraryOptions(b, target, optimize, decoders));
    addDecoderSources(b, module, target, .checked, x86_simd);
    return module;
}

fn linkShippedCodecs(b: *Build, module: *Build.Module, target: Build.ResolvedTarget, x86_simd: X86Simd, use_lto: bool) void {
    // Keep unwind metadata in checked builds where codec failures
    // are diagnosed. The shipped C archive uses error returns.
    const codecs = b.createModule(.{ .target = target, .optimize = codec_mode, .link_libc = true, .unwind_tables = .none });
    addDecoderSources(b, codecs, target, if (use_lto) .shipped_lto else .shipped, x86_simd);
    const archive = b.addLibrary(.{ .name = "uidiff-codecs", .root_module = codecs, .use_lld = if (use_lto) true else null });
    if (use_lto) archive.lto = .full;
    module.linkLibrary(archive);
}

/// Adds the PNG, JPEG and WebP decoders' C sources, bounded by the limits
/// that src/value/image.zig owns.
fn addDecoderSources(b: *Build, module: *Build.Module, target: Build.ResolvedTarget, mode: CodecBuild, x86_simd: X86Simd) void {
    // Keep the screenshot path throughput-oriented and compact the other
    // codecs in the shipped binary. Checked builds keep their normal mode.
    const legacy_flags: []const []const u8 = if (mode != .checked) &.{"-Os"} else &.{};
    addStbDecoder(b, module, target, legacy_flags, x86_simd, mode == .shipped_lto);
    addJpegDecoder(b, module, target, legacy_flags);
    const webp = b.dependency("libwebp", .{});
    module.addIncludePath(webp.path(""));
    // The binding requests RGBA only.
    const webp_flags = webpFlags(b, if (mode != .checked) &.{ "-DWEBP_REDUCE_CSP", "-Oz" } else &.{"-DWEBP_REDUCE_CSP"});
    module.addCSourceFiles(.{ .root = webp.path(""), .files = &(webp_common ++ webp_decoder), .flags = webp_flags });
    addWebpAllocator(b, module, webp, webp_flags);
    switch (target.result.cpu.arch) {
        .aarch64, .aarch64_be, .arm, .armeb, .thumb, .thumbeb => module.addCSourceFiles(.{
            .root = webp.path("src/dsp"),
            .files = &.{ "alpha_processing_neon.c", "dec_neon.c", "filters_neon.c", "lossless_neon.c", "rescaler_neon.c", "upsampling_neon.c", "yuv_neon.c" },
            .flags = webp_flags,
        }),
        .x86, .x86_64 => {
            const dsp = webp.path("src/dsp");
            const features = target.result.cpu.features;
            module.addCSourceFiles(.{
                .root = dsp,
                .files = &.{ "alpha_processing_sse2.c", "dec_sse2.c", "filters_sse2.c", "lossless_sse2.c", "rescaler_sse2.c", "upsampling_sse2.c", "yuv_sse2.c" },
                .flags = webp_flags,
            });
            // Upstream's CPU header omits these kernels unless the object
            // itself targets their ISA. Keep the portable build on SSE2
            // until separate dispatch objects are measured on x86 WebP inputs.
            if (std.Target.x86.featureSetHas(features, .sse4_1)) module.addCSourceFiles(.{
                .root = dsp,
                .files = &.{ "alpha_processing_sse41.c", "dec_sse41.c", "lossless_sse41.c", "upsampling_sse41.c", "yuv_sse41.c" },
                .flags = webp_flags,
            });
            if (std.Target.x86.featureSetHas(features, .avx2)) module.addCSourceFile(.{
                .file = webp.path("src/dsp/lossless_avx2.c"),
                .flags = webp_flags,
            });
        },
        else => {},
    }
}

fn addJpegDecoder(b: *Build, module: *Build.Module, target: Build.ResolvedTarget, flags: []const []const u8) void {
    const jpeg = b.dependency("libjpeg_turbo", .{});
    const neon = target.result.cpu.arch == .aarch64 and
        std.Target.aarch64.featureSetHas(target.result.cpu.features, .neon);
    const files = b.addWriteFiles();
    const headers = files.getDirectory();

    // The wrapper always requests native-size 8-bit RGBA or CMYK.
    _ = files.add("jconfig.h",
        \\#ifndef UIDIFF_JCONFIG_H
        \\#define UIDIFF_JCONFIG_H
        \\#define JPEG_LIB_VERSION 62
        \\#define MEM_SRCDST_SUPPORTED 1
        \\#define BITS_IN_JSAMPLE 8
        \\#ifdef _WIN32
        \\#ifndef __RPCNDR_H__
        \\typedef unsigned char boolean;
        \\#endif
        \\#define HAVE_BOOLEAN
        \\#if !defined(_BASETSD_H_) && !defined(_BASETSD_H)
        \\typedef short INT16;
        \\typedef signed int INT32;
        \\#endif
        \\#define XMD_H
        \\#endif
        \\#endif
    );
    _ = files.add("jconfigint.h", b.fmt(
        \\#ifndef UIDIFF_JCONFIGINT_H
        \\#define UIDIFF_JCONFIGINT_H
        \\#define BUILD "uidiff"
        \\#define HIDDEN __attribute__((visibility("hidden")))
        \\#define INLINE __inline__
        \\#define THREAD_LOCAL __thread
        \\#define PACKAGE_NAME "libjpeg-turbo"
        \\#define VERSION "3.2.1"
        \\#define SIZEOF_SIZE_T __SIZEOF_SIZE_T__
        \\#if __SIZEOF_LONG__ == __SIZEOF_SIZE_T__
        \\#define HAVE_BUILTIN_CTZL
        \\#endif
        \\#define FALLTHROUGH __attribute__((fallthrough));
        \\#define SIMD_ARCHITECTURE {s}
        \\{s}
        \\#endif
    , .{ if (neon) "ARM64" else "NONE", if (neon) "#define WITH_SIMD 1" else "" }));
    module.addIncludePath(headers);
    module.addIncludePath(jpeg.path("src"));
    module.addIncludePath(jpeg.path("simd"));
    module.addIncludePath(b.path("src/codec"));
    const vendor_flags = std.mem.concat(b.allocator, []const u8, &.{
        &codec_section_flags,                                                                                                                        &fuzz_coverage_flags, flags,
        &.{ "-fvisibility=hidden", "-DNO_GETENV", "-include", b.root.joinString(b.allocator, "src/codec/jpeg_build_config.h") catch @panic("OOM") },
    }) catch @panic("OOM");
    module.addCSourceFile(.{ .file = b.path("src/codec/jpeg.c"), .flags = &(codec_section_flags ++ fuzz_coverage_flags) });
    module.addCSourceFiles(.{ .root = jpeg.path("src"), .flags = vendor_flags, .files = &.{
        "jcomapi.c",            "jdapimin.c",           "jdatasrc.c",           "jdhuff.c",
        "jdinput.c",            "jdmarker.c",           "jdphuff.c",            "jmemmgr.c",
        "wrapper/jdapistd-8.c", "wrapper/jdcoefct-8.c", "wrapper/jddctmgr-8.c", "wrapper/jdmainct-8.c",
        "wrapper/jdpostct-8.c", "wrapper/jdsample-8.c", "wrapper/jidctint-8.c", "wrapper/jutils-8.c",
    } });

    // These generated edits only apply to the pinned upstream revision.
    var master = readDependencySource(b, jpeg, "src/jdmaster.c");
    for ([_]struct { []const u8, []const u8, usize }{
        .{ "cinfo->data_precision == 8", "1", 4 },
        .{ "cinfo->data_precision <= 8", "1", 6 },
        .{ "cinfo->data_precision == 12", "0", 5 },
        .{ "cinfo->data_precision <= 12", "0", 6 },
    }) |edit| master = replaceExactly(b.allocator, master, edit[0], edit[1], edit[2]);
    module.addCSourceFile(.{ .file = files.add("jdmaster.c", modifiedJpeg(b, master)), .flags = vendor_flags });

    var backing = readDependencySource(b, jpeg, "src/jmemnobs.c");
    backing = replaceExactly(b.allocator, backing, "#include \"jmemsys.h\"", "#include \"jpeg.h\"\n#include \"jmemsys.h\"", 1);
    backing = replaceExactly(b.allocator, backing, "MALLOC(sizeofobject)", "uidiff_codec_malloc(sizeofobject)", 2);
    backing = replaceExactly(b.allocator, backing, "free(object);", "uidiff_codec_free(object);", 2);
    module.addCSourceFile(.{ .file = files.add("jmemnobs.c", modifiedJpeg(b, backing)), .flags = vendor_flags });

    const colour = readDependencySource(b, jpeg, "src/jdcolor.c");
    const colour_types = replaceRange(b, colour, "  switch (cinfo->out_color_space) {\n  case JCS_GRAYSCALE:", "  case JCS_CMYK:\n#ifdef D_LOSSLESS_SUPPORTED",
        \\  switch (cinfo->out_color_space) {
        \\  case JCS_EXT_RGBA:
        \\    cinfo->out_color_components = 4;
        \\    switch (cinfo->jpeg_color_space) {
        \\    case JCS_YCbCr:
        \\#ifdef WITH_SIMD
        \\      if (jsimd_set_ycc_rgb(cinfo)) {
        \\        cconvert->pub._color_convert = jsimd_color_deconvert;
        \\        break;
        \\      }
        \\#endif
        \\      cconvert->pub._color_convert = ycc_extrgbx_convert;
        \\      build_ycc_rgb_table(cinfo);
        \\      break;
        \\    case JCS_GRAYSCALE:
        \\      cconvert->pub._color_convert = gray_extrgbx_convert;
        \\      break;
        \\    case JCS_RGB:
        \\      cconvert->pub._color_convert = rgb_extrgbx_convert;
        \\      break;
        \\    default:
        \\      ERREXIT(cinfo, JERR_CONVERSION_NOTIMPL);
        \\    }
        \\    break;
        \\
        \\
    );
    const supported_colour = replaceRange(b, colour_types, "    /* Permit null conversion to same output space */", "\n  }\n\n  if (cinfo->quantize_colors)", "    ERREXIT(cinfo, JERR_CONVERSION_NOTIMPL);");
    module.addCSourceFile(.{ .file = files.add("jdcolor.c", modifiedJpeg(b, supported_colour)), .flags = vendor_flags });

    // Upstream's x86 paths need NASM. Its Arm64 paths use C intrinsics.
    if (neon) addJpegNeon(b, jpeg, files, module, vendor_flags);
}

fn addJpegNeon(b: *Build, jpeg: *Build.Dependency, files: *Build.Step.WriteFile, module: *Build.Module, flags: []const []const u8) void {
    var compat = readDependencySource(b, jpeg, "simd/arm/neon-compat.h.in");
    for ([_][]const u8{ "HAVE_VLD1_S16_X3", "HAVE_VLD1_U16_X2", "HAVE_VLD1Q_U8_X4" }) |feature| {
        compat = replaceExactly(b.allocator, compat, b.fmt("#cmakedefine {s}", .{feature}), b.fmt("#define {s} 1", .{feature}), 1);
    }
    _ = files.add("neon-compat.h", compat);
    var dispatch = readDependencySource(b, jpeg, "simd/jsimd.c");
    for ([_]struct { []const u8, []const u8 }{
        .{ "HIDDEN unsigned int\njsimd_set_rgb_ycc(", "HIDDEN unsigned int\njsimd_set_ycc_rgb(" },
        .{ "HIDDEN unsigned int\njsimd_set_ycc_rgb565(", "HIDDEN void\njsimd_color_deconvert(" },
        .{ "HIDDEN unsigned int\njsimd_set_h2v1_downsample(", "HIDDEN unsigned int\njsimd_set_h2v1_upsample(" },
        .{ "HIDDEN unsigned int\njsimd_set_h2v1_merged_upsample(", "HIDDEN unsigned int\njsimd_set_idct_islow(" },
    }) |edit| dispatch = replaceRange(b, dispatch, edit[0], edit[1], "");
    const tail = "HIDDEN unsigned int\njsimd_set_idct_ifast(";
    if (std.mem.count(u8, dispatch, tail) != 1) @panic("pinned JPEG SIMD dispatch changed");
    dispatch = dispatch[0..std.mem.indexOf(u8, dispatch, tail).?];
    dispatch = replaceExactly(b.allocator, dispatch, "SET_SIMD_EXTRGB_COLOR_DECONVERTER(neon);", "cinfo->cconvert->color_convert_simd = jsimd_ycc_extrgbx_convert_neon;", 1);
    module.addCSourceFile(.{ .file = files.add("jsimd.c", modifiedJpeg(b, dispatch)), .flags = flags });
    module.addCSourceFiles(.{ .root = jpeg.path("simd/arm"), .flags = flags, .files = &.{
        "aarch64/jsimdcpu.c", "jdcolor-neon.c", "jdsample-neon.c", "jidctint-neon.c",
    } });
}

fn modifiedJpeg(b: *Build, source: []const u8) []const u8 {
    return b.fmt("/* Copyright (c) 2026 uidiff contributors. Build-time adaptation for uidiff. */\n{s}", .{source});
}

fn replaceRange(b: *Build, source: []const u8, first: []const u8, last: []const u8, replacement: []const u8) []u8 {
    if (std.mem.count(u8, source, first) != 1 or std.mem.count(u8, source, last) != 1)
        @panic("pinned source range anchors changed");
    const begin = std.mem.indexOf(u8, source, first).?;
    const end = std.mem.indexOfPos(u8, source, begin + first.len, last) orelse @panic("pinned source end anchor changed");
    return replaceExactly(b.allocator, source, source[begin..end], replacement, 1);
}

fn addStbDecoder(b: *Build, module: *Build.Module, target: Build.ResolvedTarget, legacy_flags: []const []const u8, x86_simd: X86Simd, use_lto: bool) void {
    addZlibNg(b, module, target, x86_simd, use_lto);
    module.addIncludePath(b.dependency("stb", .{}).path(""));
    module.addIncludePath(b.path("src/codec"));
    const inflate_flags = [_][]const u8{"-DZLIBNG_NATIVE_API"} ++ codec_section_flags ++ fuzz_coverage_flags;
    module.addCSourceFile(.{ .file = b.path("src/codec/rgba_png.c"), .flags = &inflate_flags });
    module.addCSourceFile(.{
        .file = b.path("src/codec/stb.c"),
        .flags = std.mem.concat(b.allocator, []const u8, &.{
            &.{b.fmt("-DSTBI_MAX_DIMENSIONS={d}", .{values.max_extent})}, &codec_section_flags, &fuzz_coverage_flags, legacy_flags,
        }) catch @panic("OOM"),
    });
}

/// zlib-ng's CMake generates three headers; derive them from the pinned sources.
fn zlibHeaders(b: *Build, target: Build.ResolvedTarget) *Build.Step.WriteFile {
    const zlib = b.dependency("zlib_ng", .{});
    const files = b.addWriteFiles();
    const api = replaceExactly(b.allocator, readDependencySource(b, zlib, "zlib-ng.h.in"), "@ZLIB_SYMBOL_PREFIX@", "", 2);
    _ = files.add("zlib-ng.h", b.fmt("#define UIDIFF_PNG_COMPRESSION_LEVEL {d}\n#define UIDIFF_ZLIB_CRC {d}\n{s}", .{
        png_compression_level, @intFromBool(zlibPngCrc(target)), api,
    }));
    const conf = readDependencySource(b, zlib, "zconf-ng.h.in");
    _ = files.add("zconf-ng.h", if (target.result.os.tag == .windows) conf else replaceExactly(b.allocator, conf, "#ifdef HAVE_UNISTD_H", "#if 1", 1));
    _ = files.add("zlib_name_mangling-ng.h", readDependencySource(b, zlib, "zlib_name_mangling.h.empty"));
    return files;
}

fn readDependencySource(b: *Build, dependency: *Build.Dependency, name: []const u8) []u8 {
    b.dependOnFileContents(dependency.path(name));
    return dependency.builder.root.root_dir.handle.readFileAlloc(b.graph.io, b.pathJoin(&.{ dependency.builder.root.sub_path, name }), b.allocator, .limited(256 * 1024)) catch
        @panic("cannot read pinned decoder source");
}

// Only the PNG writer initializes this compressor. Preserve the selected
// upstream level's tuning and drop the other compression strategies.
fn zlibDeflate(b: *Build, zlib: *Build.Dependency) Build.LazyPath {
    const source = readDependencySource(b, zlib, "deflate.c");
    const table = std.mem.indexOf(u8, source, "static const config configuration_table[10] = {") orelse @panic("zlib-ng level table changed");
    const medium = std.mem.indexOfPos(u8, source, table, "#else\n/* 3 */") orelse @panic("zlib-ng medium strategy changed");
    const tag = b.fmt("/* {d} */ ", .{png_compression_level});
    const entry = (std.mem.indexOfPos(u8, source, medium, tag) orelse @panic("zlib-ng compression level missing")) + tag.len;
    const close = (std.mem.indexOfScalarPos(u8, source, entry, '}') orelse @panic("zlib-ng level entry changed")) + 1;
    const end = (std.mem.indexOfPos(u8, source, close, "}};") orelse @panic("zlib-ng level table changed")) + 3;
    if (std.mem.indexOf(u8, source[entry..close], "deflate_medium") == null) @panic("zlib-ng level no longer uses the medium strategy");
    var text = replaceExactly(b.allocator, source, source[table..end], b.fmt("static const config configuration = {s};", .{source[entry..close]}), 1);
    const dispatch =
        \\s->level == 0 ? deflate_stored(s, flush) :
        \\                 s->strategy == Z_HUFFMAN_ONLY ? deflate_huff(s, flush) :
        \\                 s->strategy == Z_RLE ? deflate_rle(s, flush) :
        \\                 (*(configuration_table[s->level].func))(s, flush);
    ;
    text = replaceExactly(b.allocator, text, dispatch, "deflate_medium(s, flush);", 1);
    text = replaceExactly(b.allocator, text, "configuration_table[s->level]", "configuration", 1);
    text = replaceExactly(b.allocator, text, "configuration_table[level]", "configuration", 5);
    text = replaceExactly(b.allocator, text, "level < 0 || level > 9 || strategy < 0 || strategy > Z_FIXED", "level != UIDIFF_PNG_COMPRESSION_LEVEL || strategy != Z_DEFAULT_STRATEGY", 2);
    return b.addWriteFiles().add("deflate.c", text);
}

// Gzip is disabled, but the upstream dispatcher publishes gzip folding
// callbacks by default. Drop those references while preserving its ABI.
fn zlibDispatch(b: *Build, zlib: *Build.Dependency) Build.LazyPath {
    const source = readDependencySource(b, zlib, "functable.c");
    const first = std.mem.indexOf(u8, source, "static void crc32_fold_stub(") orelse @panic("zlib-ng dispatch stubs changed");
    const last = std.mem.indexOfPos(u8, source, first, "static void inflate_fast_stub(") orelse @panic("zlib-ng dispatch stubs changed");
    var text = replaceExactly(b.allocator, source, source[first..last], "", 1);
    const removed = [_]struct { []const u8, usize }{
        .{ "    ft.crc32_fold = &crc32_fold_c;\n    ft.crc32_fold_copy = &crc32_fold_copy_c;\n    ft.crc32_fold_final = &crc32_fold_final_c;\n    ft.crc32_fold_reset = &crc32_fold_reset_c;\n", 2 },
        .{ "        ft.crc32_fold = &crc32_fold_pclmulqdq;\n        ft.crc32_fold_copy = &crc32_fold_pclmulqdq_copy;\n        ft.crc32_fold_final = &crc32_fold_pclmulqdq_final;\n        ft.crc32_fold_reset = &crc32_fold_pclmulqdq_reset;\n", 1 },
        .{ "        ft.crc32_fold = &crc32_fold_vpclmulqdq;\n        ft.crc32_fold_copy = &crc32_fold_vpclmulqdq_copy;\n        ft.crc32_fold_final = &crc32_fold_vpclmulqdq_final;\n        ft.crc32_fold_reset = &crc32_fold_vpclmulqdq_reset;\n", 1 },
        .{ "        ft.crc32_fold = &crc32_fold_armv8;\n        ft.crc32_fold_copy = &crc32_fold_copy_armv8;\n", 1 },
        .{ "        ft.crc32_fold = &crc32_fold_loongarch64;\n        ft.crc32_fold_copy = &crc32_fold_copy_loongarch64;\n", 1 },
        .{ "    FUNCTABLE_VERIFY_ASSIGN(ft, crc32_fold);\n    FUNCTABLE_VERIFY_ASSIGN(ft, crc32_fold_copy);\n    FUNCTABLE_VERIFY_ASSIGN(ft, crc32_fold_final);\n    FUNCTABLE_VERIFY_ASSIGN(ft, crc32_fold_reset);\n", 1 },
    };
    for (removed) |edit| text = replaceExactly(b.allocator, text, edit[0], "", edit[1]);
    const fold_callbacks =
        \\    crc32_fold_stub,
        \\    crc32_fold_copy_stub,
        \\    crc32_fold_final_stub,
        \\    crc32_fold_reset_stub,
    ;
    text = replaceExactly(b.allocator, text, fold_callbacks, "    NULL,\n    NULL,\n    NULL,\n    NULL,", 1);
    return b.addWriteFiles().add("functable.c", text);
}

fn replaceExactly(allocator: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8, expected_count: usize) []u8 {
    if (std.mem.count(u8, text, from) != expected_count)
        std.debug.panic("pinned decoder edit expected {d} matches for {s}", .{ expected_count, from });
    return std.mem.replaceOwned(u8, allocator, text, from, to) catch @panic("OOM");
}

fn zlibPngCrc(target: Build.ResolvedTarget) bool {
    return switch (target.result.cpu.arch) {
        .aarch64 => std.Target.aarch64.featureSetHas(target.result.cpu.features, .crc),
        .x86_64 => true,
        else => false,
    };
}

/// Builds the zlib stream and PNG checksum routines. Only x86 uses runtime dispatch.
fn addZlibNg(b: *Build, module: *Build.Module, target: Build.ResolvedTarget, x86_simd: X86Simd, use_lto: bool) void {
    const zlib = b.dependency("zlib_ng", .{});
    const headers = zlibHeaders(b, target).getDirectory();
    module.addIncludePath(headers);
    module.addIncludePath(zlib.path(""));
    const arch = target.result.cpu.arch;
    const os = target.result.os.tag;
    var common: std.ArrayList([]const u8) = .empty;
    common.appendSlice(b.allocator, &(.{ "-DZLIBNG_NATIVE_API", "-DNO_GZIP", "-DWITH_OPTIM", "-DHAVE_BUILTIN_CTZ", "-DHAVE_BUILTIN_CTZLL", "-DHAVE_ATTRIBUTE_ALIGNED", "-DHAVE_BUILTIN_ASSUME_ALIGNED", "-DHAVE_VISIBILITY_HIDDEN", "-DNDEBUG" } ++ codec_section_flags ++ fuzz_coverage_flags)) catch @panic("OOM");
    if (os == .linux) common.appendSlice(b.allocator, &.{ "-DHAVE_SYS_AUXV_H", "-DHAVE_LINUX_AUXVEC_H" }) catch @panic("OOM");
    const stream = [_][]const u8{
        "adler32.c",
        "deflate_medium.c",
        "inflate.c",
        "insert_string.c",
        "insert_string_roll.c",
        "trees.c",
    };
    const scalar = [_][]const u8{
        "arch/generic/adler32_c.c",     "arch/generic/adler32_fold_c.c", "arch/generic/chunkset_c.c",     "arch/generic/compare256_c.c",
        "arch/generic/crc32_braid_c.c", "arch/generic/slide_hash_c.c",   "arch/generic/crc32_chorba_c.c",
    };
    switch (arch) {
        .aarch64 => {
            const neon = std.Target.aarch64.featureSetHas(target.result.cpu.features, .neon);
            const crc = zlibPngCrc(target);
            common.appendSlice(b.allocator, &.{ "-DARM_FEATURES", "-DDISABLE_RUNTIME_CPU_DETECTION", "-DWITHOUT_CHORBA" }) catch @panic("OOM");
            if (neon) common.appendSlice(b.allocator, &.{ "-DARM_NEON", "-DARM_NEON_HASLD4", "-DARM_NOCHECK_NEON=1" }) catch @panic("OOM");
            if (crc) common.appendSlice(b.allocator, &.{ "-DARM_CRC32", "-DARM_CRC32_INTRIN", "-DHAVE_ARM_ACLE_H" }) catch @panic("OOM");
            const kernels: []const []const u8 = if (neon)
                &.{ "arch/arm/adler32_neon.c", "arch/arm/chunkset_neon.c", "arch/arm/compare256_neon.c", "arch/arm/slide_hash_neon.c" }
            else
                &.{ "arch/generic/adler32_c.c", "arch/generic/adler32_fold_c.c", "arch/generic/chunkset_c.c", "arch/generic/compare256_c.c", "arch/generic/slide_hash_c.c" };
            module.addCSourceFiles(.{ .root = zlib.path(""), .files = &stream, .flags = common.items });
            module.addCSourceFiles(.{ .root = zlib.path(""), .files = kernels, .flags = common.items });
            if (crc) module.addCSourceFiles(.{
                .root = zlib.path(""),
                .files = &.{ "crc32.c", "crc32_braid_comb.c", "arch/arm/crc32_armv8.c" },
                .flags = common.items,
            });
        },
        .x86_64 => {
            // Higher zlib-ng levels call lower kernels as fallbacks. Removing
            // their prerequisite also removes the dependent dispatch levels.
            const ssse3 = x86_simd != .without_ssse3;
            const sse4 = ssse3 and x86_simd != .without_sse4;
            const avx2 = sse4 and x86_simd != .shipped and x86_simd != .without_avx2;
            const pclmul = sse4 and x86_simd != .shipped and x86_simd != .without_pclmul;
            common.appendSlice(b.allocator, &.{ "-DX86_FEATURES", "-DX86_SSE2", "-DHAVE_CPUID_GNU", "-DX86_HAVE_XSAVE_INTRIN" }) catch @panic("OOM");
            if (ssse3) common.append(b.allocator, "-DX86_SSSE3") catch @panic("OOM");
            if (sse4) common.appendSlice(b.allocator, &.{ "-DX86_SSE41", "-DX86_SSE42" }) catch @panic("OOM");
            if (avx2) common.append(b.allocator, "-DX86_AVX2") catch @panic("OOM");
            if (pclmul) common.append(b.allocator, "-DX86_PCLMULQDQ_CRC") catch @panic("OOM");
            const base = common.items;
            module.addCSourceFile(.{ .file = zlibDispatch(b, zlib), .flags = base });
            module.addCSourceFiles(.{ .root = zlib.path(""), .files = &(stream ++ scalar ++ .{ "crc32.c", "crc32_braid_comb.c", "cpu_features.c", "arch/x86/chunkset_sse2.c", "arch/x86/chorba_sse2.c", "arch/x86/compare256_sse2.c", "arch/x86/slide_hash_sse2.c" }), .flags = base });
            // Zig pins each object's CPU features, so -m flags cannot raise
            // them per file; each dispatch level is its own object instead.
            const levels = .{
                .{ "x86_features", true, std.Target.x86.featureSet(&.{.xsave}), &[_][]const u8{"arch/x86/x86_features.c"} },
                .{ "ssse3", ssse3, std.Target.x86.featureSet(&.{.ssse3}), &[_][]const u8{ "arch/x86/adler32_ssse3.c", "arch/x86/chunkset_ssse3.c" } },
                .{ "sse41", sse4, std.Target.x86.featureSet(&.{.sse4_1}), &[_][]const u8{"arch/x86/chorba_sse41.c"} },
                .{ "sse42", sse4, std.Target.x86.featureSet(&.{.sse4_2}), &[_][]const u8{"arch/x86/adler32_sse42.c"} },
                .{ "pclmul", pclmul, std.Target.x86.featureSet(&.{ .sse4_2, .pclmul }), &[_][]const u8{"arch/x86/crc32_pclmulqdq.c"} },
                .{ "avx2", avx2, std.Target.x86.featureSet(&.{ .avx2, .bmi2 }), &[_][]const u8{ "arch/x86/slide_hash_avx2.c", "arch/x86/chunkset_avx2.c", "arch/x86/compare256_avx2.c", "arch/x86/adler32_avx2.c" } },
            };
            inline for (levels) |level| {
                if (level[1]) {
                    var query = target.query;
                    query.cpu_features_add.addFeatureSet(level[2]);
                    const part = b.createModule(.{
                        .target = b.resolveTargetQuery(query),
                        .optimize = module.optimize,
                        .link_libc = true,
                        .unwind_tables = module.unwind_tables,
                    });
                    part.addIncludePath(headers);
                    part.addIncludePath(zlib.path(""));
                    part.addCSourceFiles(.{ .root = zlib.path(""), .files = level[3], .flags = base });
                    const archive = b.addLibrary(.{ .name = "zlib-ng-" ++ level[0], .root_module = part, .use_lld = if (use_lto) true else null });
                    if (use_lto) archive.lto = .full;
                    module.linkLibrary(archive);
                }
            }
        },
        else => {
            common.append(b.allocator, "-DDISABLE_RUNTIME_CPU_DETECTION") catch @panic("OOM");
            module.addCSourceFiles(.{ .root = zlib.path(""), .files = &(stream ++ scalar), .flags = common.items });
        },
    }
    // These support routines sit outside the inflate and deflate loops.
    const support_flags = if (arch == .aarch64 and os == .macos and module.optimize == .fast)
        std.mem.concat(b.allocator, []const u8, &.{ common.items, &.{"-Oz"} }) catch @panic("OOM")
    else
        common.items;
    module.addCSourceFiles(.{ .root = zlib.path(""), .files = &.{ "inftrees.c", "zutil.c" }, .flags = support_flags });
    module.addCSourceFile(.{ .file = zlibDeflate(b, zlib), .flags = common.items });
}

fn webpFlags(b: *Build, extra: []const []const u8) []const []const u8 {
    const base = [_][]const u8{b.fmt("-DWEBP_MAX_ALLOCABLE_MEMORY={d}ULL", .{values.max_decode_bytes})} ++ codec_section_flags ++ fuzz_coverage_flags;
    return std.mem.concat(b.allocator, []const u8, &.{ &base, extra }) catch @panic("OOM");
}

fn addWebpAllocator(b: *Build, module: *Build.Module, webp: *Build.Dependency, flags: []const []const u8) void {
    module.addCSourceFile(.{
        .file = webp.path("src/utils/utils.c"),
        .flags = std.mem.concat(b.allocator, []const u8, &.{ flags, &.{ "-Dmalloc=uidiff_webp_malloc", "-Dcalloc=uidiff_webp_calloc", "-Dfree=uidiff_webp_free" } }) catch @panic("OOM"),
    });
}

/// Translates the decoder headers only; the encoders' headers are the fixture generator's.
fn addDecoders(b: *Build, target: Build.ResolvedTarget) Decoders {
    const webp = b.dependency("libwebp", .{});
    const stb = b.dependency("stb", .{});
    const jpeg_c = b.addTranslateC(.{ .root_source_file = b.path("src/codec/jpeg.h"), .target = target, .optimize = codec_mode });
    const stb_c = b.addTranslateC(.{ .root_source_file = b.path("src/codec/stb.h"), .target = target, .optimize = codec_mode });
    stb_c.addIncludePath(stb.path(""));
    stb_c.defineCMacro("STBI_NO_STDIO", null);
    const webp_c = b.addTranslateC(.{ .root_source_file = webp.path("src/webp/decode.h"), .target = target, .optimize = codec_mode });
    const zlib_c = b.addTranslateC(.{ .root_source_file = zlibHeaders(b, target).getDirectory().path(b, "zlib-ng.h"), .target = target, .optimize = codec_mode });
    return .{
        .jpeg = jpeg_c.createModule(),
        .stb = stb_c.createModule(),
        .webp = webp_c.createModule(),
        .zlib = zlib_c.createModule(),
        .memory = b.createModule(.{ .root_source_file = b.path("src/codec/memory.zig"), .target = target }),
    };
}

fn addSizeCheck(b: *Build, install_cli: *Build.Step.InstallArtifact) void {
    const checker = b.addExecutable(.{ .name = "uidiff-size", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/size.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    }) });
    const run = b.addRunArtifact(checker);
    run.addFileArg(install_cli.artifact.getEmittedBin());
    run.addArg(b.fmt("{d}", .{max_cli_bytes}));
    run.has_side_effects = true;
    b.step("size", "Check the CLI binary against its size budget").dependOn(&run.step);
}

fn addTests(b: *Build, target: Build.ResolvedTarget, optimize: Optimize, decoders: Decoders, install_cli: *Build.Step.InstallArtifact, host_generator: *Build.Step.Compile, x86_simd: X86Simd) void {
    const uidiff = addCheckedLibrary(b, target, optimize, decoders, x86_simd);
    const cases = b.createModule(.{ .root_source_file = b.path("tests/fixtures.zig"), .target = target, .optimize = optimize });
    _ = addE2e(b, target, optimize, uidiff, cases, install_cli);
    const filter = b.option([]const u8, "test-filter", "Run only the library's unit tests that match");
    const step = b.step("test", "Run unit, layer, order, fixture and fuzz-corpus tests");
    if (filter) |pattern| {
        // Other test binaries could filter out every use of the library, and
        // with it the decoders' allocation hooks they link against.
        const filters = b.allocator.dupe([]const u8, &.{pattern}) catch @panic("OOM");
        step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = uidiff, .filters = filters })).step);
        return;
    }
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = uidiff })).step);
    for (fuzz_targets ++ [_][]const u8{"tests/decode.zig"}) |source| {
        // The styled target encodes its full output. Use safe optimization
        // for this pixel-heavy workload while retaining decoder UBSan.
        const styled = std.mem.eql(u8, source, styled_sheet_fuzz_source);
        const mode = if (styled) Optimize.safe else optimize;
        const tested = if (styled and optimize != .safe) addCheckedLibrary(b, target, .safe, decoders, x86_simd) else uidiff;
        step.dependOn(&b.addRunArtifact(b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(source),
                .target = target,
                .optimize = mode,
                .imports = &.{ .{ .name = "uidiff", .module = tested }, .{ .name = "fixtures", .module = cases } },
            }),
        })).step);
    }
    for (source_tests) |source| {
        const run = b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
        }) }));
        // These read source files outside the compiler's import graph.
        run.has_side_effects = true;
        step.dependOn(&run.step);
    }
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "uidiff", .module = uidiff }},
    }) })).step);
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/size.zig"),
        .target = target,
        .optimize = optimize,
    }) })).step);
    addFixtures(b, step, host_generator);
}

fn addThreadedTest(b: *Build, target: Build.ResolvedTarget, decoders: Decoders) void {
    const module = addCheckedLibrary(b, target, .debug, decoders, .shipped);
    module.sanitize_thread = true;
    const tests = b.addTest(.{ .root_module = module, .filters = &.{"overlapped PNG decodes"} });
    const run = b.addRunArtifact(tests);
    b.step("test-threaded", "Check overlapping decodes under ThreadSanitizer").dependOn(&run.step);
}

fn addE2e(b: *Build, target: Build.ResolvedTarget, optimize: Optimize, uidiff: *Build.Module, cases: *Build.Module, install_cli: *Build.Step.InstallArtifact) *Build.Step {
    const options = b.addOptions();
    options.addOptionPathUntracked("executable", .{ .relative = .{ .base = .install_bin, .sub_path = install_cli.artifact.out_filename } });
    options.addOption([]const u8, "usage", @embedFile("src/cli/usage.txt"));
    const runner = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/e2e.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "uidiff", .module = uidiff },
                .{ .name = "fixtures", .module = cases },
                .{ .name = "e2e_options", .module = options.createModule() },
            },
        }),
    });
    const run = b.addRunArtifact(runner);
    run.has_side_effects = true;
    run.step.dependOn(&install_cli.step);
    const step = b.step("e2e", "Run the installed uidiff CLI on screenshot pairs and error cases");
    step.dependOn(&run.step);
    return step;
}

fn addBenchmark(b: *Build, target: Build.ResolvedTarget, optimize: Optimize, uidiff: *Build.Module) void {
    const bench = b.addExecutable(.{
        .name = "uidiff-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .debug,
            .imports = &.{.{ .name = "uidiff", .module = uidiff }},
        }),
    });
    const step = b.step("bench", "Measure fixture decode, compare, sheet, file pipeline, and peak RSS");
    const before = b.option([]const u8, "bench-before", "Benchmark a custom before image");
    const after = b.option([]const u8, "bench-after", "Benchmark a custom after image");
    const scale = b.option([]const u8, "bench-scale", "Device pixels per CSS pixel for a custom pair (the CLI's default when unset)");
    if (before != null or after != null) {
        if (before) |a| if (after) |z| {
            const run = b.addRunArtifact(bench);
            run.addArgs(&.{ "custom", a, z });
            if (scale) |value| run.addArg(value);
            step.dependOn(&run.step);
            return;
        };
        step.dependOn(&b.addFail("Provide both -Dbench-before and -Dbench-after").step);
        return;
    }
    var previous: ?*Build.Step = null;
    var inputs: std.ArrayList(u8) = .empty;
    inline for (fixtures.all) |variant| {
        if (variant.change != .insert) continue;
        const run = b.addRunArtifact(bench);
        const args = .{ variant.name, variant.path(.before, .png), variant.path(.after, .png), b.fmt("{d}", .{fixtures.scale}) };
        run.addArgs(&args);
        inputs.appendSlice(b.allocator, b.fmt("{s}\t{s}\t{s}\t{s}\n", args)) catch @panic("OOM");
        if (previous) |dependency| run.step.dependOn(dependency);
        previous = &run.step;
    }
    if (previous) |dependency| step.dependOn(dependency);
    const list = b.addWriteFiles().add("bench-inputs.tsv", inputs.items);
    const install_list = b.addInstallFile(list, "bench-inputs.tsv");
    b.step("bench-inputs", "Write the fixture workloads used by the benchmark").dependOn(&install_list.step);
}

fn fixtureGenerator(b: *Build, target: Build.ResolvedTarget, decoders: Decoders) *Build.Step.Compile {
    const optimize: Optimize = .safe;
    const webp = b.dependency("libwebp", .{});
    const stb = b.dependency("stb", .{});
    const stb_write = b.addTranslateC(.{ .root_source_file = stb.path("stb_image_write.h"), .target = target, .optimize = optimize });
    stb_write.defineCMacro("STBI_WRITE_NO_STDIO", null);
    const webp_encode = b.addTranslateC(.{ .root_source_file = webp.path("src/webp/encode.h"), .target = target, .optimize = optimize });
    const library = b.createModule(libraryOptions(b, target, optimize, decoders));
    const codecs = b.createModule(.{ .target = target, .optimize = codec_mode, .link_libc = true });
    addStbDecoder(b, codecs, target, &.{}, .shipped, false);
    addJpegDecoder(b, codecs, target, &.{"-Os"});
    codecs.addIncludePath(webp.path(""));
    const config = b.addWriteFiles();
    _ = config.add("src/webp/config.h", "/* Use the same scalar encoder on every host. */\n");
    codecs.addIncludePath(config.getDirectory());
    const flags = webpFlags(b, &.{ "-DHAVE_CONFIG_H", "-ffp-contract=off" });
    codecs.addCSourceFiles(.{ .root = webp.path(""), .files = &(webp_common ++ webp_decoder ++ webp_encoder), .flags = flags });
    addWebpAllocator(b, codecs, webp, flags);
    library.linkLibrary(b.addLibrary(.{ .name = "uidiff-fixture-codecs", .root_module = codecs }));
    const module = b.createModule(.{
        .root_source_file = b.path("tests/fixtures/generate.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "uidiff", .module = library },
            .{ .name = "stb_write_c", .module = stb_write.createModule() },
            .{ .name = "webp_encode_c", .module = webp_encode.createModule() },
            .{ .name = "codec_memory", .module = decoders.memory },
        },
    });
    module.addIncludePath(stb.path(""));
    module.addCSourceFile(.{ .file = b.path("tests/fixtures/stb_write.c"), .flags = &.{"-ffp-contract=off"} });
    return b.addExecutable(.{ .name = "uidiff-fixtures", .root_module = module });
}

/// Regenerates or checks the fixtures by running the generator on the host.
fn addFixtures(b: *Build, test_step: *Build.Step, generator: *Build.Step.Compile) void {
    const target = b.graph.host;
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = generator.root_module })).step);
    const run = b.addRunArtifact(generator);
    const generated = run.addOutputDirectoryArg("images");
    const update = b.addUpdateSourceFiles();
    inline for (fixtures.files) |file| {
        update.addCopyFileToSource(generated.path(b, file), fixtures.directory ++ "/" ++ file);
    }
    b.step("fixtures", "Regenerate the synthetic screenshot fixtures in the source tree").dependOn(&update.step);

    const options = b.addOptions();
    options.addOptionPathDirectory("generated", generated);
    const fresh = b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/fixtures/fresh.zig"),
        .target = target,
        .optimize = .debug,
        .imports = &.{.{ .name = "fixture_options", .module = options.createModule() }},
    }) }));
    // It compares files in the source tree, which the compiler does not track.
    fresh.has_side_effects = true;
    test_step.dependOn(&fresh.step);
}

test {
    std.testing.refAllDecls(@This());
}
