//! Builds and patches vendored C codecs for the CLI, tests and fixture generators.
const std = @import("std");
const value = @import("../src/value.zig");
const Optimize = std.builtin.Optimize;
const Build = std.Build;

/// Translated decoder headers: only the codec bindings import these.
pub const Decoders = struct {
    jpeg: *Build.Module,
    stb: *Build.Module,
    webp: *Build.Module,
    zlib: *Build.Module,
    memory: *Build.Module,
    png_format: *Build.Module,
};

/// How a build compiles the C decoders: in their own measured mode for the
/// shipped binary, or inside the Zig module, in its mode with UBSan, for
/// tests and fuzzing (without coverage feedback; see fuzz_coverage_flags).
const CodecBuild = enum { shipped, shipped_lto, checked, fixture };
/// Selects object code or LTO bitcode for the shipped decoder archive.
pub const ShippedLinkage = enum { objects, lto };

/// Selects the zlib-ng x86 dispatch paths for a build.
pub const X86Simd = enum {
    /// The released binary's levels: SSE2 through SSE4.2 and PCLMULQDQ, no AVX2.
    shipped,
    /// Every level upstream dispatches to, AVX2 included.
    all_levels,
    /// SSE2 only: drops SSSE3 and the levels built on it.
    without_ssse3,
    /// SSE2 and SSSE3: drops SSE4 and the levels built on it.
    without_sse4,
};

// Build-owned text carries the pinned filename through each edit.
const PinnedSource = struct {
    name: []const u8,
    text: []const u8,

    fn replaceExactly(self: *PinnedSource, allocator: std.mem.Allocator, from: []const u8, to: []const u8, expected_count: usize) void {
        self.requireMatches(from, expected_count);
        self.text = std.mem.replaceOwned(u8, allocator, self.text, from, to) catch @panic("OOM");
    }

    fn replaceRange(self: *PinnedSource, allocator: std.mem.Allocator, first: []const u8, last: []const u8, replacement: []const u8) void {
        self.requireMatches(first, 1);
        self.requireMatches(last, 1);
        const begin = self.indexFrom(first, 0);
        const end = self.indexFrom(last, begin + first.len);
        self.replaceExactly(allocator, self.text[begin..end], replacement, 1);
    }

    fn valueBetween(self: PinnedSource, anchor: []const u8, delimiter: u8) []const u8 {
        self.requireMatches(anchor, 1);
        const begin = self.indexFrom(anchor, 0) + anchor.len;
        const end = self.indexFrom(&.{delimiter}, begin);
        return self.text[begin..end];
    }

    fn requireMatches(self: PinnedSource, from: []const u8, expected_count: usize) void {
        const match_count = std.mem.count(u8, self.text, from);
        if (match_count != expected_count) self.failMatch(from, expected_count, match_count);
    }

    fn indexFrom(self: PinnedSource, from: []const u8, start: usize) usize {
        return std.mem.indexOfPos(u8, self.text, start, from) orelse self.failMatch(from, 1, 0);
    }

    fn failMatch(self: PinnedSource, from: []const u8, expected_count: usize, match_count: usize) noreturn {
        const prefix = from[0..@min(from.len, 64)];
        std.debug.panic("{s}: pinned codec edit \"{f}\" expected {d} matches, found {d}", .{
            self.name, std.zig.fmtString(prefix), expected_count, match_count,
        });
    }
};

/// ReleaseSafe keeps safety checks enabled in the fixture generators.
pub const fixture_mode: Optimize = .safe;

// Translate headers in the shipped Zig mode even in a checked build.
const header_mode: Optimize = .safe;
const codec_mode: Optimize = .fast;
const jpeg_public_config = "#define UIDIFF_JPEG_PUBLIC_CONFIG 1\n#include \"build_config.h\"\n#undef UIDIFF_JPEG_PUBLIC_CONFIG\n";
const png_compression_level = 2;
const max_pinned_source_bytes = 256 * 1024;
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

/// Links the compact decoder archive into a shipped library module.
pub fn linkShippedCodecs(b: *Build, module: *Build.Module, target: Build.ResolvedTarget, x86_simd: X86Simd, linkage: ShippedLinkage) void {
    // Keep unwind metadata in checked builds where codec failures
    // are diagnosed. The shipped C archive uses error returns.
    const codecs = b.createModule(.{ .target = target, .optimize = codec_mode, .link_libc = true, .unwind_tables = .none });
    const mode: CodecBuild = switch (linkage) {
        .objects => .shipped,
        .lto => .shipped_lto,
    };
    addDecoderSources(b, codecs, target, mode, x86_simd);
    const archive = b.addLibrary(.{ .name = "uidiff-codecs", .root_module = codecs, .use_lld = if (linkage == .lto) true else null });
    if (linkage == .lto) archive.lto = .full;
    module.linkLibrary(archive);
}

/// Translates the decoder headers only; the encoders' headers are the fixture generator's.
pub fn addDecoders(b: *Build, target: Build.ResolvedTarget) Decoders {
    const webp = b.dependency("libwebp", .{});
    const stb = b.dependency("stb", .{});
    const jpeg = b.dependency("libjpeg_turbo", .{});
    const jpeg_config = b.addWriteFiles();
    _ = jpeg_config.add("jconfig.h", jpeg_public_config);
    const jpeg_c = b.addTranslateC(.{ .root_source_file = b.path("src/codec/jpeg/bridge.h"), .target = target, .optimize = header_mode });
    jpeg_c.addIncludePath(jpeg_config.getDirectory());
    jpeg_c.addIncludePath(jpeg.path("src"));
    jpeg_c.addIncludePath(b.path("src/codec/jpeg"));
    const stb_c = b.addTranslateC(.{ .root_source_file = b.path("src/codec/png/stb.h"), .target = target, .optimize = header_mode });
    stb_c.addIncludePath(stb.path(""));
    stb_c.defineCMacro("STBI_NO_STDIO", null);
    const webp_c = b.addTranslateC(.{ .root_source_file = webp.path("src/webp/decode.h"), .target = target, .optimize = header_mode });
    const zlib_c = b.addTranslateC(.{ .root_source_file = zlibHeaders(b, target).getDirectory().path(b, "zlib-ng.h"), .target = target, .optimize = header_mode });
    return .{
        .jpeg = jpeg_c.createModule(),
        .stb = stb_c.createModule(),
        .webp = webp_c.createModule(),
        .zlib = zlib_c.createModule(),
        .png_format = b.createModule(.{ .root_source_file = b.path("src/codec/png/format.zig"), .target = target }),
        .memory = b.createModule(.{ .root_source_file = b.path("src/codec/memory.zig"), .target = target }),
    };
}

/// Configures the generator's C encoders and returns the fixture codec archive
/// for the caller to link into its uidiff library.
pub fn addFixtureCodecs(b: *Build, target: Build.ResolvedTarget, generator: *Build.Module) *Build.Step.Compile {
    const webp = b.dependency("libwebp", .{});
    const stb = b.dependency("stb", .{});
    const stb_write = b.addTranslateC(.{ .root_source_file = stb.path("stb_image_write.h"), .target = target, .optimize = fixture_mode });
    stb_write.defineCMacro("STBI_WRITE_NO_STDIO", null);
    const webp_encode = b.addTranslateC(.{ .root_source_file = webp.path("src/webp/encode.h"), .target = target, .optimize = fixture_mode });
    const codecs = b.createModule(.{ .target = target, .optimize = codec_mode, .link_libc = true });
    addDecoderSources(b, codecs, target, .fixture, .shipped);
    const archive = b.addLibrary(.{ .name = "uidiff-fixture-codecs", .root_module = codecs });
    generator.addImport("stb_write_c", stb_write.createModule());
    generator.addImport("webp_encode_c", webp_encode.createModule());
    generator.addIncludePath(stb.path(""));
    generator.addCSourceFile(.{ .file = b.path("tools/fixtures/stb_write.c"), .flags = &.{"-ffp-contract=off"} });
    return archive;
}

/// Compiles the pinned scalar JPEG encoder for the host fixture generator.
pub fn jpegFixtureModule(b: *Build, generator: Build.LazyPath) *Build.Module {
    const jpeg = b.dependency("libjpeg_turbo", .{});
    const config = b.addWriteFiles();
    const header = config.add("jpeg_encoder.h", "#include \"jinclude.h\"\n#include \"jpeglib.h\"\n");
    const c = b.addTranslateC(.{ .root_source_file = header, .target = b.graph.host, .optimize = fixture_mode });
    c.addIncludePath(config.getDirectory());
    c.addIncludePath(jpeg.path("src"));
    c.addIncludePath(b.path("src/codec/jpeg"));
    const module = b.createModule(.{
        .root_source_file = generator,
        .target = b.graph.host,
        .optimize = fixture_mode,
        .link_libc = true,
        .imports = &.{.{ .name = "jpeg_encode_c", .module = c.createModule() }},
    });
    configureJpeg(b, module, jpeg, config, false);
    const source = readDependencySource(b, jpeg, "CMakeLists.txt");
    const copyright_year = source.valueBetween("\nset(COPYRIGHT_YEAR \"", '"');
    var version_header = readDependencySource(b, jpeg, "src/jversion.h.in");
    version_header.replaceExactly(b.allocator, "@COPYRIGHT_YEAR@", copyright_year, 1);
    _ = config.add("jversion.h", version_header.text);
    var pinned = std.mem.tokenizeAny(u8, source.valueBetween("\nset(JPEG_SOURCES ", ')'), " \r\n\t");
    var files: std.ArrayList([]const u8) = .empty;
    while (pinned.next()) |file| {
        if (!std.mem.startsWith(u8, file, "src/") or !std.mem.endsWith(u8, file, ".c")) std.debug.panic("{s}: pinned JPEG source list contains a non-C entry", .{source.name});
        files.append(b.allocator, file) catch @panic("OOM");
    }
    module.addCSourceFiles(.{ .root = jpeg.path(""), .files = files.items, .flags = &.{"-ffp-contract=off"} });
    return module;
}

/// Compiles the decoders in the caller's module so its sanitizer settings apply.
pub fn addCheckedDecoders(b: *Build, module: *Build.Module, target: Build.ResolvedTarget, x86_simd: X86Simd) void {
    addDecoderSources(b, module, target, .checked, x86_simd);
}

// Adds the decoders' C sources, bounded by the limits src/value/image.zig owns.
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
        // uidiff decodes WebP at full size only, so the rescaler is omitted.
        .checked => &.{ "-DWEBP_REDUCE_CSP", "-DWEBP_REDUCE_SIZE" },
        .shipped, .shipped_lto => &.{ "-DWEBP_REDUCE_CSP", "-DWEBP_REDUCE_SIZE", "-Oz" },
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
        &codec_section_flags,
        &fuzz_coverage_flags,
        flags,
        &.{ "-fvisibility=hidden", "-DNO_GETENV", "-include", b.root.joinString(b.allocator, "src/codec/jpeg/build_config.h") catch @panic("OOM") },
    }) catch @panic("OOM");
    module.addCSourceFile(.{ .file = b.path("src/codec/jpeg/bridge.c"), .flags = &(codec_section_flags ++ fuzz_coverage_flags) });
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
    }) |edit| master.replaceExactly(b.allocator, edit[0], edit[1], edit[2]);
    module.addCSourceFile(.{ .file = files.add("jdmaster.c", modifiedJpeg(b, master.text)), .flags = vendor_flags });

    var backing = readDependencySource(b, jpeg, "src/jmemnobs.c");
    backing.replaceExactly(b.allocator, "#include \"jmemsys.h\"", "#include \"memory.h\"\n#include \"jmemsys.h\"", 1);
    backing.replaceExactly(b.allocator, "MALLOC(sizeofobject)", "uidiff_codec_malloc(sizeofobject)", 2);
    backing.replaceExactly(b.allocator, "free(object);", "uidiff_codec_free(object);", 2);
    module.addCSourceFile(.{ .file = files.add("jmemnobs.c", modifiedJpeg(b, backing.text)), .flags = vendor_flags });

    var colour = readDependencySource(b, jpeg, "src/jdcolor.c");
    colour.replaceRange(b.allocator, "  switch (cinfo->out_color_space) {\n  case JCS_GRAYSCALE:", "  case JCS_CMYK:\n#ifdef D_LOSSLESS_SUPPORTED",
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
    colour.replaceRange(b.allocator, "    /* Permit null conversion to same output space */", "\n  }\n\n  if (cinfo->quantize_colors)", "    ERREXIT(cinfo, JERR_CONVERSION_NOTIMPL);");
    module.addCSourceFile(.{ .file = files.add("jdcolor.c", modifiedJpeg(b, colour.text)), .flags = vendor_flags });

    // Upstream's x86 paths need NASM. Its Arm64 paths use C intrinsics.
    if (neon) addJpegNeon(b, jpeg, files, module, vendor_flags);
}

fn configureJpeg(b: *Build, module: *Build.Module, jpeg: *Build.Dependency, files: *Build.Step.WriteFile, neon: bool) void {
    const source = readDependencySource(b, jpeg, "CMakeLists.txt");
    const version = source.valueBetween("\nset(VERSION ", ')');
    _ = std.SemanticVersion.parse(version) catch std.debug.panic("{s}: invalid pinned JPEG version", .{source.name});
    module.addCMacro("UIDIFF_JPEG_VERSION", b.fmt("\"{s}\"", .{version}));
    if (neon) module.addCMacro("UIDIFF_JPEG_NEON", "1");
    _ = files.add("jconfig.h", jpeg_public_config);
    _ = files.add("jconfigint.h", "#define UIDIFF_JPEG_INTERNAL_CONFIG 1\n#include \"build_config.h\"\n#undef UIDIFF_JPEG_INTERNAL_CONFIG\n");
    module.addIncludePath(files.getDirectory());
    module.addIncludePath(jpeg.path("src"));
    module.addIncludePath(jpeg.path("simd"));
    module.addIncludePath(b.path("src/codec/jpeg"));
}

fn addJpegNeon(b: *Build, jpeg: *Build.Dependency, files: *Build.Step.WriteFile, module: *Build.Module, flags: []const []const u8) void {
    var compat = readDependencySource(b, jpeg, "simd/arm/neon-compat.h.in");
    for ([_][]const u8{ "HAVE_VLD1_S16_X3", "HAVE_VLD1_U16_X2", "HAVE_VLD1Q_U8_X4" }) |feature| {
        compat.replaceExactly(b.allocator, b.fmt("#cmakedefine {s}", .{feature}), b.fmt("#define {s} 1", .{feature}), 1);
    }
    _ = files.add("neon-compat.h", compat.text);
    var dispatch = readDependencySource(b, jpeg, "simd/jsimd.c");
    for ([_]struct { []const u8, []const u8 }{
        .{ "HIDDEN unsigned int\njsimd_set_rgb_ycc(", "HIDDEN unsigned int\njsimd_set_ycc_rgb(" },
        .{ "HIDDEN unsigned int\njsimd_set_ycc_rgb565(", "HIDDEN void\njsimd_color_deconvert(" },
        .{ "HIDDEN unsigned int\njsimd_set_h2v1_downsample(", "HIDDEN unsigned int\njsimd_set_h2v1_upsample(" },
        .{ "HIDDEN unsigned int\njsimd_set_h2v1_merged_upsample(", "HIDDEN unsigned int\njsimd_set_idct_islow(" },
    }) |edit| dispatch.replaceRange(b.allocator, edit[0], edit[1], "");
    const tail = "HIDDEN unsigned int\njsimd_set_idct_ifast(";
    dispatch.requireMatches(tail, 1);
    dispatch.text = dispatch.text[0..dispatch.indexFrom(tail, 0)];
    dispatch.replaceExactly(b.allocator, "SET_SIMD_EXTRGB_COLOR_DECONVERTER(neon);", "cinfo->cconvert->color_convert_simd = jsimd_ycc_extrgbx_convert_neon;", 1);
    module.addCSourceFile(.{ .file = files.add("jsimd.c", modifiedJpeg(b, dispatch.text)), .flags = flags });
    module.addCSourceFiles(.{ .root = jpeg.path("simd/arm"), .flags = flags, .files = &.{
        "aarch64/jsimdcpu.c", "jdcolor-neon.c", "jdsample-neon.c", "jidctint-neon.c",
    } });
}

fn modifiedJpeg(b: *Build, source: []const u8) []const u8 {
    return b.fmt("/* Copyright (c) 2026 uidiff contributors. Build-time adaptation for uidiff. */\n{s}", .{source});
}

fn addStbDecoder(b: *Build, module: *Build.Module, target: Build.ResolvedTarget, legacy_flags: []const []const u8, x86_simd: X86Simd, mode: CodecBuild) void {
    addZlibNg(b, module, target, x86_simd, mode);
    module.addIncludePath(b.dependency("stb", .{}).path(""));
    module.addIncludePath(b.path("src/codec"));
    module.addCSourceFile(.{
        .file = b.path("src/codec/png/stb.c"),
        .flags = std.mem.concat(b.allocator, []const u8, &.{
            &.{b.fmt("-DSTBI_MAX_DIMENSIONS={d}", .{value.max_extent})}, &codec_section_flags, &fuzz_coverage_flags, legacy_flags,
        }) catch @panic("OOM"),
    });
}

/// zlib-ng's CMake generates three headers; derive them from the pinned sources.
fn zlibHeaders(b: *Build, target: Build.ResolvedTarget) *Build.Step.WriteFile {
    const zlib = b.dependency("zlib_ng", .{});
    const files = b.addWriteFiles();
    var api = readDependencySource(b, zlib, "zlib-ng.h.in");
    api.replaceExactly(b.allocator, "@ZLIB_SYMBOL_PREFIX@", "", 2);
    _ = files.add("zlib-ng.h", b.fmt("#define UIDIFF_PNG_COMPRESSION_LEVEL {d}\n{s}\n", .{
        png_compression_level, api.text,
    }));
    var conf = readDependencySource(b, zlib, "zconf-ng.h.in");
    if (target.result.os.tag != .windows) conf.replaceExactly(b.allocator, "#ifdef HAVE_UNISTD_H", "#if 1", 1);
    _ = files.add("zconf-ng.h", conf.text);
    _ = files.add("zlib_name_mangling-ng.h", readDependencySource(b, zlib, "zlib_name_mangling.h.empty").text);
    return files;
}

fn readDependencySource(b: *Build, dependency: *Build.Dependency, name: []const u8) PinnedSource {
    b.dependOnFileContents(dependency.path(name));
    const contents = dependency.builder.root.root_dir.handle.readFileAlloc(b.graph.io, b.pathJoin(&.{ dependency.builder.root.sub_path, name }), b.allocator, .limited(max_pinned_source_bytes)) catch |err|
        std.debug.panic("cannot read pinned codec file {s}: {t}", .{ name, err });
    return .{ .name = name, .text = contents };
}

// Only the PNG writer initializes this compressor. Preserve the selected
// upstream level's tuning and drop the other compression strategies.
fn zlibDeflate(b: *Build, zlib: *Build.Dependency) Build.LazyPath {
    var source = readDependencySource(b, zlib, "deflate.c");
    const table_anchor = "static const config configuration_table[10] = {";
    // Levels 1 and 2 of upstream's default build, where NO_QUICK_STRATEGY is unset.
    const levels_anchor = "#else\n/* 1 */";
    const table_end = " /* max compression */\n\n/* Note: the deflate()";
    source.requireMatches(table_anchor, 1);
    source.requireMatches(levels_anchor, 1);
    const table = source.indexFrom(table_anchor, 0);
    const levels = source.indexFrom(levels_anchor, table);
    const tag = b.fmt("/* {d} */ ", .{png_compression_level});
    const levels_end = source.indexFrom("#endif", levels);
    const section: PinnedSource = .{ .name = source.name, .text = source.text[levels..levels_end] };
    const entry = section.valueBetween(tag, '}');
    const strategy: PinnedSource = .{ .name = source.name, .text = entry };
    strategy.requireMatches("deflate_fast", 1);
    source.replaceRange(b.allocator, table_anchor, table_end, b.fmt("static const config configuration = {s}}};", .{entry}));
    const dispatch =
        \\s->level == 0 ? deflate_stored(s, flush) :
        \\                 s->strategy == Z_HUFFMAN_ONLY ? deflate_huff(s, flush) :
        \\                 s->strategy == Z_RLE ? deflate_rle(s, flush) :
        \\                 (*(configuration_table[s->level].func))(s, flush);
    ;
    source.replaceExactly(b.allocator, dispatch, "deflate_fast(s, flush);", 1);
    source.replaceExactly(b.allocator, "configuration_table[s->level]", "configuration", 1);
    source.replaceExactly(b.allocator, "configuration_table[level]", "configuration", 5);
    source.replaceExactly(b.allocator, "level < 0 || level > 9 || strategy < 0 || strategy > Z_FIXED", "level != UIDIFF_PNG_COMPRESSION_LEVEL || strategy != Z_DEFAULT_STRATEGY", 2);
    // deflateReset keeps the window's high-water mark, so matching read the
    // bytes a stream's previous strip left past the lookahead, and a strip's
    // output depended on which worker, and so how many CPUs, compressed it.
    // Clearing the mark makes fill_window zero them as for a fresh stream.
    source.replaceExactly(b.allocator, "    if (ret == Z_OK)\n        lm_init(strm->state);", "    if (ret == Z_OK) {\n        strm->state->high_water = 0;\n        lm_init(strm->state);\n    }", 1);
    return b.addWriteFiles().add("deflate.c", source.text);
}

// Gzip is disabled, but the upstream dispatcher publishes gzip folding
// callbacks by default. Drop those references while preserving its ABI.
fn zlibDispatch(b: *Build, zlib: *Build.Dependency) Build.LazyPath {
    var source = readDependencySource(b, zlib, "functable.c");
    source.replaceRange(b.allocator, "static void crc32_fold_stub(", "static void inflate_fast_stub(", "");
    const removed = [_]struct { []const u8, usize }{
        .{ "    ft.crc32_fold = &crc32_fold_c;\n    ft.crc32_fold_copy = &crc32_fold_copy_c;\n    ft.crc32_fold_final = &crc32_fold_final_c;\n    ft.crc32_fold_reset = &crc32_fold_reset_c;\n", 2 },
        .{ "        ft.crc32_fold = &crc32_fold_pclmulqdq;\n        ft.crc32_fold_copy = &crc32_fold_pclmulqdq_copy;\n        ft.crc32_fold_final = &crc32_fold_pclmulqdq_final;\n        ft.crc32_fold_reset = &crc32_fold_pclmulqdq_reset;\n", 1 },
        .{ "        ft.crc32_fold = &crc32_fold_vpclmulqdq;\n        ft.crc32_fold_copy = &crc32_fold_vpclmulqdq_copy;\n        ft.crc32_fold_final = &crc32_fold_vpclmulqdq_final;\n        ft.crc32_fold_reset = &crc32_fold_vpclmulqdq_reset;\n", 1 },
        .{ "        ft.crc32_fold = &crc32_fold_armv8;\n        ft.crc32_fold_copy = &crc32_fold_copy_armv8;\n", 1 },
        .{ "        ft.crc32_fold = &crc32_fold_loongarch64;\n        ft.crc32_fold_copy = &crc32_fold_copy_loongarch64;\n", 1 },
        .{ "    FUNCTABLE_VERIFY_ASSIGN(ft, crc32_fold);\n    FUNCTABLE_VERIFY_ASSIGN(ft, crc32_fold_copy);\n    FUNCTABLE_VERIFY_ASSIGN(ft, crc32_fold_final);\n    FUNCTABLE_VERIFY_ASSIGN(ft, crc32_fold_reset);\n", 1 },
    };
    for (removed) |edit| source.replaceExactly(b.allocator, edit[0], "", edit[1]);
    // deflate_fast, the only compiled strategy, uses longest_match alone;
    // the slow matcher and compare256 serve the dropped strategies.
    for ([_][]const u8{ "longest_match_slow", "compare256" }) |name| {
        source.replaceExactly(b.allocator, b.fmt("    FUNCTABLE_VERIFY_ASSIGN(ft, {s});\n", .{name}), "", 1);
        source.replaceExactly(b.allocator, b.fmt("    {s}_stub,\n", .{name}), "    NULL,\n", 1);
        // One assignment per CPU variant; the kernels stay referenced, unused.
        source.replaceExactly(b.allocator, b.fmt("ft.{s} = &", .{name}), "(void)&", 10);
    }
    source.replaceRange(b.allocator, "static uint32_t compare256_stub(", "static uint32_t crc32_stub(", "");
    source.replaceRange(b.allocator, "static uint32_t longest_match_slow_stub(", "static void slide_hash_stub(", "");
    // The PCLMUL kernel also extracts lanes with SSE4.1.
    source.replaceExactly(b.allocator, "if (cf.x86.has_pclmulqdq) {", "if (cf.x86.has_pclmulqdq && cf.x86.has_sse41) {", 1);
    const fold_callbacks =
        \\    crc32_fold_stub,
        \\    crc32_fold_copy_stub,
        \\    crc32_fold_final_stub,
        \\    crc32_fold_reset_stub,
    ;
    source.replaceExactly(b.allocator, fold_callbacks, "    NULL,\n    NULL,\n    NULL,\n    NULL,", 1);
    return b.addWriteFiles().add("functable.c", source.text);
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
        "deflate_fast.c",
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
            const avx2 = x86_simd == .all_levels;
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
    const base = [_][]const u8{b.fmt("-DWEBP_MAX_ALLOCABLE_MEMORY={d}ULL", .{value.max_decode_bytes})} ++ codec_section_flags ++ fuzz_coverage_flags;
    return std.mem.concat(b.allocator, []const u8, &.{ &base, extra }) catch @panic("OOM");
}

fn addWebpAllocator(b: *Build, module: *Build.Module, webp: *Build.Dependency, flags: []const []const u8) void {
    module.addCSourceFile(.{
        .file = webp.path("src/utils/utils.c"),
        .flags = std.mem.concat(b.allocator, []const u8, &.{ flags, &.{ "-Dmalloc=uidiff_codec_malloc", "-Dcalloc=uidiff_codec_calloc", "-Dfree=uidiff_codec_free" } }) catch @panic("OOM"),
    });
}
