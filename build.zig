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
const CodecBuild = enum { shipped, shipped_lto, checked, fixture };
const X86Simd = enum { shipped, baseline, without_ssse3, without_sse4, without_avx2 };

// The shipped Zig binary retains runtime safety checks. The C decoders
// run with UBSan in the checked test build and in fuzzing.
const shipped_mode: Optimize = .safe;
const codec_mode: Optimize = .fast;
const jpeg_public_config = "#define UIDIFF_JPEG_PUBLIC_CONFIG 1\n#include \"jpeg_build_config.h\"\n#undef UIDIFF_JPEG_PUBLIC_CONFIG\n";
const png_compression_level = 3;
/// The shipped CLI's size budget for every CI target. Run zig build size
/// with -Dtarget to measure a specific binary.
const max_cli_bytes = 1_200_000;
const cli_name = "uidiff";
const max_pinned_source_bytes = 256 * 1024;
const cli_source = "src/cli.zig";
const fuzz_directory = "tests/fuzz";
const styled_sheet_fuzz_source = fuzz_directory ++ "/sheet.zig";
/// Keeps clang's coverage instrumentation out of the C decoders under
/// `zig build test --fuzz`. Zig 0.17's fuzzer reads one PC per edge counter
/// from `__sancov_pcs1`, as its own backend writes them; clang writes two
/// words per edge to `__sancov_pcs` and calls comparison hooks the fuzzer
/// lacks, so instrumented C fails to link or aborts at start. The decoders are
/// still fuzzed, checked by UBSan, but without coverage feedback. Without
/// -ffuzz these flags change nothing.
const fuzz_coverage_flags = [_][]const u8{"-fno-sanitize-coverage=inline-8bit-counters,pc-table,trace-cmp"};

// The self-hosted x86_64 backend used by Debug on Linux does not emit the
// fuzzer's PC tables. The coverage runners need LLVM even in Debug.
const fuzz_use_llvm = true;
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
    if (optimize == .fast or optimize == .small)
        std.process.fatal("uidiff requires Debug or ReleaseSafe for Zig code", .{});
    const test_mode = override orelse release orelse .debug;
    const decoders = addDecoders(b, target);
    const lib = libraryOptions(b, target, optimize, decoders);
    const uidiff = b.addModule("uidiff", lib);
    linkShippedCodecs(b, uidiff, target, x86_simd, .shipped);
    // Enable LTO for the measured Linux musl release targets. Windows opts in for benchmarking.
    const os = target.result.os.tag;
    const arch = target.result.cpu.arch;
    const linux_musl = os == .linux and target.result.abi == .musl;
    const can_lto = optimize == shipped_mode and (linux_musl or os == .windows) and
        (arch == .aarch64 or arch == .x86_64);
    const requested_lto = b.option(bool, "cli-lto", "Override LTO for Linux musl or Windows ReleaseSafe CLIs");
    if (requested_lto == true and !can_lto) @panic("-Dcli-lto=true requires an arm64 or x86-64 Linux musl or Windows ReleaseSafe target");
    // Keep bitcode archives out of the public module consumed by other builds.
    const cli_mode: CodecBuild = if (requested_lto orelse (can_lto and linux_musl)) .shipped_lto else .shipped;
    const cli_library = if (cli_mode == .shipped_lto) b.createModule(lib) else uidiff;
    if (cli_mode == .shipped_lto) linkShippedCodecs(b, cli_library, target, x86_simd, cli_mode);

    const version = packageVersion(b);
    const cli_options = b.addOptions();
    cli_options.addOption([]const u8, "version", version);
    const cli_config = cli_options.createModule();
    const cli = b.addExecutable(.{
        .name = cli_name,
        .use_lld = if (cli_mode == .shipped_lto) true else null,
        .root_module = b.createModule(.{
            .root_source_file = b.path(cli_source),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .debug,
            // The stripped CLI emits message-only panics. Windows retains
            // the unwind metadata used by its exception machinery.
            .unwind_tables = if (optimize != .debug and target.result.os.tag != .windows) .none else null,
            .imports = &.{
                .{ .name = "uidiff", .module = cli_library },
                .{ .name = "cli_options", .module = cli_config },
            },
        }),
    });
    // Keep the Windows Zig and CRT objects native. LLD can still optimize the C archives.
    if (cli_mode == .shipped_lto and linux_musl) cli.lto = .full;
    const install_cli = b.addInstallArtifact(cli, .{});
    b.getInstallStep().dependOn(&install_cli.step);
    inline for (.{ "LICENSE", "THIRD_PARTY_NOTICES" }) |notice| b.installFile(notice, "bin/" ++ notice);
    addSizeCheck(b, install_cli);
    const generator = fixtureGenerator(b, target, decoders);
    const host_generator = if (target.query.isNative()) generator else fixtureGenerator(b, b.graph.host, addDecoders(b, b.graph.host));
    addTests(b, target, test_mode, decoders, install_cli, host_generator, x86_simd, cli_config, version);
    addThreadedTest(b, target, decoders);
    addPngTestGates(b, target, test_mode, decoders);
    addBenchmark(b, target, optimize, uidiff);
    const fixture_build = b.step("fixture-generator", "Build the fixture generator for the selected target");
    fixture_build.dependOn(&generator.step);
}

fn packageVersion(b: *Build) []const u8 {
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const manifest = std.zon.parse.fromSlice(struct { version: []const u8 }, .{
        .gpa = b.allocator,
        .arena = b.allocator,
        .source = @embedFile("build.zig.zon"),
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| std.process.fatal("cannot read package version from build.zig.zon: {t}", .{err});
    return manifest.version;
}

/// The library module's options, without its C decoders.
fn libraryOptions(b: *Build, target: Build.ResolvedTarget, optimize: Optimize, decoders: Decoders) Build.Module.CreateOptions {
    const defaults = b.addOptions();
    defaults.addOption([]const u8, "filter", "");
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
            .{ .name = "required_test_options", .module = defaults.createModule() },
        }) catch @panic("OOM"),
    };
}

fn addCheckedLibrary(b: *Build, target: Build.ResolvedTarget, optimize: Optimize, decoders: Decoders, x86_simd: X86Simd) *Build.Module {
    const module = b.createModule(libraryOptions(b, target, optimize, decoders));
    addDecoderSources(b, module, target, .checked, x86_simd);
    module.addImport("uidiff_test_canvas", b.createModule(.{
        .root_source_file = b.path("src/testing/canvas.zig"),
        .target = target,
        .optimize = optimize,
    }));
    return module;
}

fn linkShippedCodecs(b: *Build, module: *Build.Module, target: Build.ResolvedTarget, x86_simd: X86Simd, mode: CodecBuild) void {
    // Keep unwind metadata in checked builds where codec failures
    // are diagnosed. The shipped C archive uses error returns.
    const codecs = b.createModule(.{ .target = target, .optimize = codec_mode, .link_libc = true, .unwind_tables = .none });
    addDecoderSources(b, codecs, target, mode, x86_simd);
    const archive = b.addLibrary(.{ .name = "uidiff-codecs", .root_module = codecs, .use_lld = if (mode == .shipped_lto) true else null });
    if (mode == .shipped_lto) archive.lto = .full;
    module.linkLibrary(archive);
}

/// Adds the PNG, JPEG and WebP decoders' C sources, bounded by the limits
/// that src/value/image.zig owns.
fn addDecoderSources(b: *Build, module: *Build.Module, target: Build.ResolvedTarget, mode: CodecBuild, x86_simd: X86Simd) void {
    // Keep the screenshot path throughput-oriented and compact the other
    // codecs in the shipped binary. Checked builds keep their normal mode.
    const legacy_flags: []const []const u8 = if (mode != .checked) &.{"-Os"} else &.{};
    addStbDecoder(b, module, target, if (mode == .fixture) &.{} else legacy_flags, x86_simd, mode);
    addJpegDecoder(b, module, target, legacy_flags);
    const webp = b.dependency("libwebp", .{});
    module.addIncludePath(webp.path(""));
    const extra_flags: []const []const u8 = switch (mode) {
        .fixture => &.{ "-DHAVE_CONFIG_H", "-ffp-contract=off" },
        .checked => &.{"-DWEBP_REDUCE_CSP"},
        .shipped, .shipped_lto => &.{ "-DWEBP_REDUCE_CSP", "-Oz" },
    };
    const webp_flags = webpFlags(b, extra_flags);
    const source: []const []const u8 = if (mode == .fixture)
        &(webp_common ++ webp_decoder ++ webp_encoder)
    else
        &(webp_common ++ webp_decoder);
    module.addCSourceFiles(.{ .root = webp.path(""), .files = source, .flags = webp_flags });
    addWebpAllocator(b, module, webp, webp_flags);
    if (mode == .fixture) {
        const config = b.addWriteFiles();
        _ = config.add("src/webp/config.h", "/* Use the same scalar encoder on every host. */\n");
        module.addIncludePath(config.getDirectory());
        return;
    }
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
    configureJpeg(b, module, jpeg, files, neon);
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

    // These edits assume the bridge and JPEG probe reject every non-8-bit frame.
    var master = readDependencySource(b, jpeg, "src/jdmaster.c");
    for ([_]struct { []const u8, []const u8, usize }{
        .{ "cinfo->data_precision == 8", "1", 4 },
        .{ "cinfo->data_precision <= 8", "1", 6 },
        .{ "cinfo->data_precision == 12", "0", 5 },
        .{ "cinfo->data_precision <= 12", "0", 6 },
    }) |edit| master = replaceExactly(b.allocator, master, edit[0], edit[1], edit[2]);
    module.addCSourceFile(.{ .file = files.add("jdmaster.c", modifiedJpeg(b, master)), .flags = vendor_flags });

    var backing = readDependencySource(b, jpeg, "src/jmemnobs.c");
    backing = replaceExactly(b.allocator, backing, "#include \"jmemsys.h\"", "#include \"codec_memory.h\"\n#include \"jmemsys.h\"", 1);
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

fn configureJpeg(b: *Build, module: *Build.Module, jpeg: *Build.Dependency, files: *Build.Step.WriteFile, neon: bool) void {
    const source = readDependencySource(b, jpeg, "CMakeLists.txt");
    const version = pinnedValue(source, "\nset(VERSION ", ')');
    _ = std.SemanticVersion.parse(version) catch @panic("pinned JPEG version is not a version number");
    module.addCMacro("UIDIFF_JPEG_VERSION", b.fmt("\"{s}\"", .{version}));
    if (neon) module.addCMacro("UIDIFF_JPEG_NEON", "1");
    _ = files.add("jconfig.h", jpeg_public_config);
    _ = files.add("jconfigint.h", "#define UIDIFF_JPEG_INTERNAL_CONFIG 1\n#include \"jpeg_build_config.h\"\n#undef UIDIFF_JPEG_INTERNAL_CONFIG\n");
    module.addIncludePath(files.getDirectory());
    module.addIncludePath(jpeg.path("src"));
    module.addIncludePath(jpeg.path("simd"));
    module.addIncludePath(b.path("src/codec"));
}

fn pinnedValue(source: []const u8, anchor: []const u8, delimiter: u8) []const u8 {
    if (std.mem.count(u8, source, anchor) != 1) @panic("pinned source value anchor changed");
    const begin = std.mem.indexOf(u8, source, anchor).? + anchor.len;
    const end = std.mem.indexOfScalarPos(u8, source, begin, delimiter) orelse @panic("pinned source value has no end");
    return source[begin..end];
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

fn addStbDecoder(b: *Build, module: *Build.Module, target: Build.ResolvedTarget, legacy_flags: []const []const u8, x86_simd: X86Simd, mode: CodecBuild) void {
    addZlibNg(b, module, target, x86_simd, mode);
    module.addIncludePath(b.dependency("stb", .{}).path(""));
    module.addIncludePath(b.path("src/codec"));
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
    _ = files.add("zlib-ng.h", b.fmt("#define UIDIFF_PNG_COMPRESSION_LEVEL {d}\n{s}\n", .{
        png_compression_level, api,
    }));
    const conf = readDependencySource(b, zlib, "zconf-ng.h.in");
    _ = files.add("zconf-ng.h", if (target.result.os.tag == .windows) conf else replaceExactly(b.allocator, conf, "#ifdef HAVE_UNISTD_H", "#if 1", 1));
    _ = files.add("zlib_name_mangling-ng.h", readDependencySource(b, zlib, "zlib_name_mangling.h.empty"));
    return files;
}

fn readDependencySource(b: *Build, dependency: *Build.Dependency, name: []const u8) []u8 {
    b.dependOnFileContents(dependency.path(name));
    return dependency.builder.root.root_dir.handle.readFileAlloc(b.graph.io, b.pathJoin(&.{ dependency.builder.root.sub_path, name }), b.allocator, .limited(max_pinned_source_bytes)) catch
        @panic("cannot read pinned decoder source");
}

// Only the PNG writer initializes this compressor. Preserve the selected
// upstream level's tuning and drop the other compression strategies.
fn zlibDeflate(b: *Build, zlib: *Build.Dependency) Build.LazyPath {
    const source = readDependencySource(b, zlib, "deflate.c");
    const table_anchor = "static const config configuration_table[10] = {";
    const medium_anchor = "#else\n/* 3 */";
    const table_end = " /* max compression */\n\n/* Note: the deflate()";
    if (std.mem.count(u8, source, table_anchor) != 1 or std.mem.count(u8, source, medium_anchor) != 1)
        @panic("zlib-ng level table changed");
    const table = std.mem.indexOf(u8, source, table_anchor).?;
    const medium = std.mem.indexOfPos(u8, source, table, medium_anchor) orelse @panic("zlib-ng medium strategy changed");
    const tag = b.fmt("/* {d} */ ", .{png_compression_level});
    const medium_end = std.mem.indexOfPos(u8, source, medium, "#endif") orelse @panic("zlib-ng medium strategy has no end");
    const entry = pinnedValue(source[medium..medium_end], tag, '}');
    if (std.mem.count(u8, entry, "deflate_medium") != 1) @panic("zlib-ng level no longer uses the medium strategy");
    var text = replaceRange(b, source, table_anchor, table_end, b.fmt("static const config configuration = {s}}};", .{entry}));
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
    var text = replaceRange(b, source, "static void crc32_fold_stub(", "static void inflate_fast_stub(", "");
    const removed = [_]struct { []const u8, usize }{
        .{ "    ft.crc32_fold = &crc32_fold_c;\n    ft.crc32_fold_copy = &crc32_fold_copy_c;\n    ft.crc32_fold_final = &crc32_fold_final_c;\n    ft.crc32_fold_reset = &crc32_fold_reset_c;\n", 2 },
        .{ "        ft.crc32_fold = &crc32_fold_pclmulqdq;\n        ft.crc32_fold_copy = &crc32_fold_pclmulqdq_copy;\n        ft.crc32_fold_final = &crc32_fold_pclmulqdq_final;\n        ft.crc32_fold_reset = &crc32_fold_pclmulqdq_reset;\n", 1 },
        .{ "        ft.crc32_fold = &crc32_fold_vpclmulqdq;\n        ft.crc32_fold_copy = &crc32_fold_vpclmulqdq_copy;\n        ft.crc32_fold_final = &crc32_fold_vpclmulqdq_final;\n        ft.crc32_fold_reset = &crc32_fold_vpclmulqdq_reset;\n", 1 },
        .{ "        ft.crc32_fold = &crc32_fold_armv8;\n        ft.crc32_fold_copy = &crc32_fold_copy_armv8;\n", 1 },
        .{ "        ft.crc32_fold = &crc32_fold_loongarch64;\n        ft.crc32_fold_copy = &crc32_fold_copy_loongarch64;\n", 1 },
        .{ "    FUNCTABLE_VERIFY_ASSIGN(ft, crc32_fold);\n    FUNCTABLE_VERIFY_ASSIGN(ft, crc32_fold_copy);\n    FUNCTABLE_VERIFY_ASSIGN(ft, crc32_fold_final);\n    FUNCTABLE_VERIFY_ASSIGN(ft, crc32_fold_reset);\n", 1 },
    };
    for (removed) |edit| text = replaceExactly(b.allocator, text, edit[0], "", edit[1]);
    // The PCLMUL kernel also extracts lanes with SSE4.1.
    text = replaceExactly(b.allocator, text, "if (cf.x86.has_pclmulqdq) {", "if (cf.x86.has_pclmulqdq && cf.x86.has_sse41) {", 1);
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

/// Builds the zlib stream and PNG checksums with the available CPU kernels.
fn addZlibNg(b: *Build, module: *Build.Module, target: Build.ResolvedTarget, x86_simd: X86Simd, mode: CodecBuild) void {
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
        "crc32.c",
        "deflate_medium.c",
        "inflate.c",
        "insert_string.c",
        "insert_string_roll.c",
        "trees.c",
    };
    const scalar = [_][]const u8{
        "arch/generic/adler32_c.c",    "arch/generic/adler32_fold_c.c", "arch/generic/chunkset_c.c", "arch/generic/compare256_c.c",
        "arch/generic/slide_hash_c.c",
    };
    switch (arch) {
        .aarch64 => {
            const neon = std.Target.aarch64.featureSetHas(target.result.cpu.features, .neon);
            const static_crc = std.Target.aarch64.featureSetHas(target.result.cpu.features, .crc) and os != .windows;
            common.appendSlice(b.allocator, &.{ "-DARM_FEATURES", "-DARM_CRC32", "-DARM_CRC32_INTRIN", "-DHAVE_ARM_ACLE_H", "-DWITHOUT_CHORBA" }) catch @panic("OOM");
            if (static_crc) common.append(b.allocator, "-DDISABLE_RUNTIME_CPU_DETECTION") catch @panic("OOM");
            if (!static_crc) common.append(b.allocator, "-DWITH_ALL_FALLBACKS") catch @panic("OOM");
            if (neon) common.appendSlice(b.allocator, &.{ "-DARM_NEON", "-DARM_NEON_HASLD4", "-DARM_NOCHECK_NEON=1" }) catch @panic("OOM");
            const kernels: []const []const u8 = if (neon)
                &.{ "arch/arm/adler32_neon.c", "arch/arm/chunkset_neon.c", "arch/arm/compare256_neon.c", "arch/arm/slide_hash_neon.c" }
            else
                &scalar;
            module.addCSourceFiles(.{
                .root = zlib.path(""),
                .files = &(stream ++ .{ "arch/generic/crc32_braid_c.c", "arch/arm/crc32_armv8.c" }),
                .flags = common.items,
            });
            module.addCSourceFiles(.{ .root = zlib.path(""), .files = kernels, .flags = common.items });
            if (!static_crc) {
                if (neon) module.addCSourceFiles(.{ .root = zlib.path(""), .files = &scalar, .flags = common.items });
                module.addCSourceFile(.{ .file = zlibDispatch(b, zlib), .flags = common.items });
                module.addCSourceFiles(.{ .root = zlib.path(""), .files = &.{ "cpu_features.c", "arch/arm/arm_features.c" }, .flags = common.items });
            }
        },
        .x86_64 => {
            // Higher zlib-ng levels call lower kernels as fallbacks. Removing
            // their prerequisite also removes the dependent dispatch levels.
            const ssse3 = x86_simd != .without_ssse3;
            const sse4 = ssse3 and x86_simd != .without_sse4;
            const avx2 = sse4 and x86_simd != .shipped and x86_simd != .without_avx2;
            common.appendSlice(b.allocator, &.{ "-DX86_FEATURES", "-DX86_SSE2", "-DHAVE_CPUID_GNU", "-DX86_HAVE_XSAVE_INTRIN", "-DWITHOUT_CHORBA", "-DWITHOUT_CHORBA_SSE" }) catch @panic("OOM");
            if (ssse3) common.append(b.allocator, "-DX86_SSSE3") catch @panic("OOM");
            if (sse4) common.appendSlice(b.allocator, &.{ "-DX86_SSE41", "-DX86_SSE42" }) catch @panic("OOM");
            if (sse4) common.append(b.allocator, "-DX86_PCLMULQDQ_CRC") catch @panic("OOM");
            if (avx2) common.append(b.allocator, "-DX86_AVX2") catch @panic("OOM");
            const base = common.items;
            module.addCSourceFile(.{ .file = zlibDispatch(b, zlib), .flags = base });
            module.addCSourceFiles(.{ .root = zlib.path(""), .files = &(stream ++ scalar ++ .{ "arch/generic/crc32_braid_c.c", "cpu_features.c", "arch/x86/chunkset_sse2.c", "arch/x86/compare256_sse2.c", "arch/x86/slide_hash_sse2.c" }), .flags = base });
            // Zig pins each object's CPU features, so -m flags cannot raise
            // them per file; each dispatch level is its own object instead.
            const levels = .{
                .{ "x86_features", true, std.Target.x86.featureSet(&.{.xsave}), &[_][]const u8{"arch/x86/x86_features.c"} },
                .{ "ssse3", ssse3, std.Target.x86.featureSet(&.{.ssse3}), &[_][]const u8{ "arch/x86/adler32_ssse3.c", "arch/x86/chunkset_ssse3.c" } },
                .{ "sse42", sse4, std.Target.x86.featureSet(&.{.sse4_2}), &[_][]const u8{"arch/x86/adler32_sse42.c"} },
                .{ "pclmul", sse4, std.Target.x86.featureSet(&.{ .sse4_1, .pclmul }), &[_][]const u8{"arch/x86/crc32_pclmulqdq.c"} },
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
                    const archive = b.addLibrary(.{ .name = "zlib-ng-" ++ level[0], .root_module = part, .use_lld = if (mode == .shipped_lto) true else null });
                    if (mode == .shipped_lto) archive.lto = .full;
                    module.linkLibrary(archive);
                }
            }
        },
        else => {
            common.append(b.allocator, "-DDISABLE_RUNTIME_CPU_DETECTION") catch @panic("OOM");
            module.addCSourceFiles(.{ .root = zlib.path(""), .files = &(stream ++ scalar ++ .{"arch/generic/crc32_braid_c.c"}), .flags = common.items });
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
        .flags = std.mem.concat(b.allocator, []const u8, &.{ flags, &.{ "-Dmalloc=uidiff_codec_malloc", "-Dcalloc=uidiff_codec_calloc", "-Dfree=uidiff_codec_free" } }) catch @panic("OOM"),
    });
}

/// Translates the decoder headers only; the encoders' headers are the fixture generator's.
fn addDecoders(b: *Build, target: Build.ResolvedTarget) Decoders {
    const webp = b.dependency("libwebp", .{});
    const stb = b.dependency("stb", .{});
    const jpeg = b.dependency("libjpeg_turbo", .{});
    const jpeg_config = b.addWriteFiles();
    _ = jpeg_config.add("jconfig.h", jpeg_public_config);
    const jpeg_c = b.addTranslateC(.{ .root_source_file = b.path("src/codec/jpeg.h"), .target = target, .optimize = shipped_mode });
    jpeg_c.addIncludePath(jpeg_config.getDirectory());
    jpeg_c.addIncludePath(jpeg.path("src"));
    jpeg_c.addIncludePath(b.path("src/codec"));
    const stb_c = b.addTranslateC(.{ .root_source_file = b.path("src/codec/stb.h"), .target = target, .optimize = shipped_mode });
    stb_c.addIncludePath(stb.path(""));
    stb_c.defineCMacro("STBI_NO_STDIO", null);
    const webp_c = b.addTranslateC(.{ .root_source_file = webp.path("src/webp/decode.h"), .target = target, .optimize = shipped_mode });
    const zlib_c = b.addTranslateC(.{ .root_source_file = zlibHeaders(b, target).getDirectory().path(b, "zlib-ng.h"), .target = target, .optimize = shipped_mode });
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

fn addTests(b: *Build, target: Build.ResolvedTarget, optimize: Optimize, decoders: Decoders, install_cli: *Build.Step.InstallArtifact, host_generator: *Build.Step.Compile, x86_simd: X86Simd, cli_config: *Build.Module, version: []const u8) void {
    const uidiff = addCheckedLibrary(b, target, optimize, decoders, x86_simd);
    const cases = b.createModule(.{ .root_source_file = b.path("tests/fixtures.zig"), .target = target, .optimize = optimize });
    const uidiff_testing = addTestingModule(b, uidiff);
    _ = addE2e(b, target, optimize, uidiff, uidiff_testing, cases, install_cli, version);
    const filter = b.option([]const u8, "test-filter", "Run only the library's unit tests that match");
    const step = b.step("test", "Run unit, layer, order, fixture and fuzz-corpus tests");
    const filters = if (filter) |pattern| b.allocator.dupe([]const u8, &.{pattern}) catch @panic("OOM") else &.{};
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = uidiff, .filters = filters, .use_llvm = fuzz_use_llvm })).step);
    for ([_][]const u8{ "tests/compare.zig", "tests/sheet.zig" }) |source| {
        const scenarios = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "uidiff", .module = uidiff },
                .{ .name = "uidiff_testing", .module = uidiff_testing },
            },
        });
        step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = scenarios, .filters = filters })).step);
    }
    if (filter != null) return;
    const inventory = b.addSystemCommand(&.{ "bash", "scripts/count-fuzz-targets.sh" });
    const fuzz_count = inventory.addOutputFileArg("fuzz-target-count.txt");
    const fuzz_count_install = b.addInstallFile(fuzz_count, "fuzz-target-count.txt");
    b.step("fuzz-target-count", "Discover fuzz tests from the compiled runners").dependOn(&fuzz_count_install.step);
    addFuzzInventory(b, inventory, uidiff);
    const fuzz_sources = fuzzSources(b);
    const checked_sources = b.allocator.alloc([]const u8, fuzz_sources.len + 1) catch @panic("OOM");
    @memcpy(checked_sources[0..fuzz_sources.len], fuzz_sources);
    checked_sources[fuzz_sources.len] = "tests/decode.zig";
    for (checked_sources, 0..) |source, index| {
        // The styled target encodes its full output. Use safe optimization
        // for this pixel-heavy workload while retaining decoder UBSan.
        const styled = std.mem.eql(u8, source, styled_sheet_fuzz_source);
        const mode = if (styled) Optimize.safe else optimize;
        const tested = if (styled and optimize != .safe) addCheckedLibrary(b, target, .safe, decoders, x86_simd) else uidiff;
        const fuzz_helpers = if (tested == uidiff) uidiff_testing else addTestingModule(b, tested);
        const test_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = mode,
            .imports = &.{
                .{ .name = "uidiff", .module = tested },
                .{ .name = "uidiff_testing", .module = fuzz_helpers },
                .{ .name = "fixtures", .module = cases },
            },
        });
        if (std.mem.eql(u8, source, cli_source)) test_module.addImport("cli_options", cli_config);
        step.dependOn(&b.addRunArtifact(b.addTest(.{
            .root_module = test_module,
            .use_llvm = if (index < fuzz_sources.len) fuzz_use_llvm else null,
        })).step);
        if (index < fuzz_sources.len) addFuzzInventory(b, inventory, test_module);
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

fn addTestingModule(b: *Build, uidiff: *Build.Module) *Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/testing.zig"),
        .target = uidiff.resolved_target,
        .optimize = uidiff.optimize,
        // Zig assigns the painter source to one module across both test roots.
        .imports = &.{
            .{ .name = "uidiff", .module = uidiff },
            .{ .name = "uidiff_test_canvas", .module = uidiff.import_table.get("uidiff_test_canvas").? },
        },
    });
}

fn fuzzSources(b: *Build) []const []const u8 {
    const io = b.graph.io;
    const path = b.pathJoin(&.{ b.root.sub_path, fuzz_directory });
    const dir = b.root.root_dir.handle.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        // The source package exports the library and omits external test runners.
        error.FileNotFound => return &.{cli_source},
        else => return std.process.fatal("cannot open " ++ fuzz_directory ++ ": {t}", .{err}),
    };
    defer dir.close(io);
    b.dependOnDirectoryContents(b.path(fuzz_directory));
    var iterator = dir.iterate();
    var sources: std.ArrayList([]const u8) = .empty;
    sources.append(b.allocator, cli_source) catch @panic("OOM");
    while (iterator.next(io) catch |err| std.process.fatal("cannot list " ++ fuzz_directory ++ ": {t}", .{err})) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig"))
            sources.append(b.allocator, b.fmt(fuzz_directory ++ "/{s}", .{entry.name})) catch @panic("OOM");
    }
    std.mem.sort([]const u8, sources.items, {}, alphabetic);
    return sources.items;
}

fn alphabetic(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn addFuzzInventory(b: *Build, inventory: *Build.Step.Run, module: *Build.Module) void {
    // Fuzz tests start with "fuzz". Run just their seed checks to get the
    // runner's actual count without running the other unit tests twice.
    const filters = b.allocator.dupe([]const u8, &.{"fuzz "}) catch @panic("OOM");
    inventory.addArtifactArg(b.addTest(.{ .root_module = module, .filters = filters }));
}

fn addThreadedTest(b: *Build, target: Build.ResolvedTarget, decoders: Decoders) void {
    const module = addCheckedLibrary(b, target, .debug, decoders, .shipped);
    module.sanitize_thread = true;
    addRequiredTest(b, module, "test-threaded", "Check overlapping decodes and encoding under ThreadSanitizer", "overlapped ");
}

fn addPngTestGates(b: *Build, target: Build.ResolvedTarget, optimize: Optimize, decoders: Decoders) void {
    const rows = addCheckedLibrary(b, target, optimize, decoders, .shipped);
    addRequiredTest(b, rows, "test-png-rows", "Check the RGB8 streaming row paths", "RGB8");
    if (target.result.cpu.arch != .x86_64) {
        b.step("test-x86-fallback", "Check PNG dictionary wrapping without AVX2")
            .dependOn(&b.addFail("test-x86-fallback requires an x86_64 target").step);
        return;
    }
    var query = target.query;
    query.cpu_model = .baseline;
    const baseline = b.resolveTargetQuery(query);
    const fallback = addCheckedLibrary(b, baseline, optimize, addDecoders(b, baseline), .without_avx2);
    addRequiredTest(b, fallback, "test-x86-fallback", "Check PNG dictionary wrapping without AVX2", "streaming PNG matches procedural RGBA across dictionary wraps");
}

fn addRequiredTest(b: *Build, library: *Build.Module, name: []const u8, description: []const u8, filter: []const u8) void {
    const options = b.addOptions();
    options.addOption([]const u8, "filter", filter);
    library.addImport("required_test_options", options.createModule());
    const filters = b.allocator.dupe([]const u8, &.{ filter, "required test selection" }) catch @panic("OOM");
    b.step(name, description).dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = library, .filters = filters })).step);
}

fn addE2e(b: *Build, target: Build.ResolvedTarget, optimize: Optimize, uidiff: *Build.Module, uidiff_testing: *Build.Module, cases: *Build.Module, install_cli: *Build.Step.InstallArtifact, version: []const u8) *Build.Step {
    const options = b.addOptions();
    options.addOptionPathUntracked("executable", .{ .relative = .{ .base = .install_bin, .sub_path = install_cli.artifact.out_filename } });
    options.addOption([]const u8, "usage", @embedFile("src/cli/usage.txt"));
    options.addOption([]const u8, "version", version);
    const runner = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/e2e.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "uidiff", .module = uidiff },
                .{ .name = "uidiff_testing", .module = uidiff_testing },
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
    const variants = std.json.Stringify.valueAlloc(b.allocator, std.meta.tags(X86Simd), .{}) catch @panic("OOM");
    const manifest = b.addWriteFiles().add("x86-simd-variants.json", variants);
    const install_variants = b.addInstallFile(manifest, "x86-simd-variants.json");
    b.step("bench-variants", "Write the selectable x86 SIMD variants").dependOn(&install_variants.step);
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
    addDecoderSources(b, codecs, target, .fixture, .shipped);
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
    options.addOptionPathDirectory("jpeg_generated", addJpegFixtures(b));
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

fn addJpegFixtures(b: *Build) Build.LazyPath {
    const jpeg = b.dependency("libjpeg_turbo", .{});
    const config = b.addWriteFiles();
    const header = config.add("jpeg_encoder.h", "#include \"jinclude.h\"\n#include \"jpeglib.h\"\n");
    const c = b.addTranslateC(.{ .root_source_file = header, .target = b.graph.host, .optimize = .safe });
    c.addIncludePath(config.getDirectory());
    c.addIncludePath(jpeg.path("src"));
    c.addIncludePath(b.path("src/codec"));
    const module = b.createModule(.{
        .root_source_file = b.path("tests/fixtures/jpeg_generate.zig"),
        .target = b.graph.host,
        .optimize = .safe,
        .link_libc = true,
        .imports = &.{.{ .name = "jpeg_encode_c", .module = c.createModule() }},
    });
    configureJpeg(b, module, jpeg, config, false);
    const source = readDependencySource(b, jpeg, "CMakeLists.txt");
    const copyright_year = pinnedValue(source, "\nset(COPYRIGHT_YEAR \"", '"');
    const version_header = readDependencySource(b, jpeg, "src/jversion.h.in");
    _ = config.add("jversion.h", replaceExactly(b.allocator, version_header, "@COPYRIGHT_YEAR@", copyright_year, 1));
    var pinned = std.mem.tokenizeAny(u8, pinnedValue(source, "\nset(JPEG_SOURCES ", ')'), " \r\n\t");
    var files: std.ArrayList([]const u8) = .empty;
    while (pinned.next()) |file| {
        if (!std.mem.startsWith(u8, file, "src/") or !std.mem.endsWith(u8, file, ".c")) @panic("pinned JPEG source list contains a non-C entry");
        files.append(b.allocator, file) catch @panic("OOM");
    }
    module.addCSourceFiles(.{ .root = jpeg.path(""), .files = files.items, .flags = &.{"-ffp-contract=off"} });
    const run = b.addRunArtifact(b.addExecutable(.{ .name = "uidiff-jpeg-fixtures", .root_module = module }));
    const output = run.addOutputDirectoryArg("jpeg-fixtures");
    const update = b.addUpdateSourceFiles();
    for (fixtures.jpeg.profiles) |profile| {
        update.addCopyFileToSource(output.path(b, profile.file), b.fmt("{s}/{s}", .{ fixtures.jpeg.directory, profile.file }));
    }
    b.step("jpeg-fixtures", "Regenerate the small JPEG profile fixtures with the pinned encoder").dependOn(&update.step);
    return output;
}

test {
    std.testing.refAllDecls(@This());
}
