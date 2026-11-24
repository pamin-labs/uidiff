//! Builds the CLI, codec bindings, tests, fixtures, benchmark and size check.
const std = @import("std");
const fixtures = @import("tests/fixtures.zig");
const values = @import("src/value.zig");
const Optimize = std.builtin.Optimize;
const Build = std.Build;

/// Translated decoder headers: only the codec bindings import these.
const Decoders = struct {
    stb: *Build.Module,
    webp: *Build.Module,
    zlib: *Build.Module,
    memory: *Build.Module,
};

/// How a build compiles the C decoders: in their own measured mode for the
/// shipped binary, or inside the Zig module, in its mode with UBSan, for
/// tests and fuzzing (without coverage feedback; see fuzz_coverage_flags).
const CodecBuild = enum { shipped, checked };

// The shipped Zig binary retains runtime safety checks. The C decoders
// run with UBSan in the checked test build and in fuzzing.
const shipped_mode: Optimize = .safe;
const codec_mode: Optimize = .fast;
const png_compression_level = 4;
/// The shipped CLI's size budget for every CI target. Run zig build size
/// with -Dtarget to measure a specific binary.
const max_cli_bytes = 1_200_000;
const cli_name = "uidiff";
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
    const uidiff = b.addModule("uidiff", libraryOptions(b, target, optimize, decoders));
    linkCodecs(b, uidiff, target, .shipped);

    const cli = b.addExecutable(.{
        .name = cli_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .debug,
            // The stripped CLI emits message-only panics. Windows retains
            // the unwind metadata used by its exception machinery.
            .unwind_tables = if (optimize != .debug and target.result.os.tag != .windows) .none else null,
            .imports = &.{.{ .name = "uidiff", .module = uidiff }},
        }),
    });
    const install_cli = b.addInstallArtifact(cli, .{});
    b.getInstallStep().dependOn(&install_cli.step);
    inline for (.{ "LICENSE", "THIRD_PARTY_NOTICES" }) |notice| b.installFile(notice, "bin/" ++ notice);
    addSizeCheck(b, install_cli);
    const generator = fixtureGenerator(b, target, decoders);
    const host_generator = if (target.query.isNative()) generator else fixtureGenerator(b, b.graph.host, addDecoders(b, b.graph.host));
    addTests(b, target, test_mode, decoders, install_cli, host_generator);
    addThreadedTest(b, target, decoders);
    addBenchmark(b, target, optimize, uidiff);
    const fuzz_count = b.addWriteFiles().add("fuzz-target-count.txt", b.fmt("{d}\n", .{fuzz_targets.len}));
    const fuzz_count_install = b.addInstallFile(fuzz_count, "fuzz-target-count.txt");
    b.step("fuzz-target-count", "Write the number of fuzz targets including the CLI").dependOn(&fuzz_count_install.step);
    const fixture_build = b.step("fixture-generator", "Build the fixture generator for the selected target");
    fixture_build.dependOn(&generator.step);
}

/// The library module's options, without its C decoders; linkCodecs adds them.
fn libraryOptions(b: *Build, target: Build.ResolvedTarget, optimize: Optimize, decoders: Decoders) Build.Module.CreateOptions {
    return .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = b.allocator.dupe(Build.Module.Import, &.{
            .{ .name = "stb_c", .module = decoders.stb },
            .{ .name = "webp_c", .module = decoders.webp },
            .{ .name = "zlib_c", .module = decoders.zlib },
            .{ .name = "codec_memory", .module = decoders.memory },
        }) catch @panic("OOM"),
    };
}

fn addCheckedLibrary(b: *Build, target: Build.ResolvedTarget, optimize: Optimize, decoders: Decoders) *Build.Module {
    const module = b.createModule(libraryOptions(b, target, optimize, decoders));
    linkCodecs(b, module, target, .checked);
    return module;
}

fn linkCodecs(b: *Build, module: *Build.Module, target: Build.ResolvedTarget, mode: CodecBuild) void {
    switch (mode) {
        .checked => addDecoderSources(b, module, target, .checked),
        .shipped => {
            // Keep unwind metadata in checked builds where codec failures
            // are diagnosed. The shipped C archive uses error returns.
            const codecs = b.createModule(.{ .target = target, .optimize = codec_mode, .link_libc = true, .unwind_tables = .none });
            addDecoderSources(b, codecs, target, .shipped);
            module.linkLibrary(b.addLibrary(.{ .name = "uidiff-codecs", .root_module = codecs }));
        },
    }
}

/// Adds the PNG, JPEG and WebP decoders' C sources, bounded by the limits
/// that src/value/image.zig owns.
fn addDecoderSources(b: *Build, module: *Build.Module, target: Build.ResolvedTarget, mode: CodecBuild) void {
    // Keep the screenshot path throughput-oriented and compact the other
    // codecs in the shipped binary. Checked builds keep their normal mode.
    const legacy_flags: []const []const u8 = if (mode == .shipped) &.{"-Os"} else &.{};
    addStbDecoder(b, module, target, legacy_flags);
    const webp = b.dependency("libwebp", .{});
    module.addIncludePath(webp.path(""));
    // The binding requests RGBA only.
    const webp_flags = webpFlags(b, if (mode == .shipped) &.{ "-DWEBP_REDUCE_CSP", "-Os" } else &.{"-DWEBP_REDUCE_CSP"});
    module.addCSourceFiles(.{ .root = webp.path(""), .files = &(webp_common ++ webp_decoder), .flags = webp_flags });
    addWebpAllocator(b, module, webp, webp_flags);
    switch (target.result.cpu.arch) {
        .aarch64, .aarch64_be, .arm, .armeb, .thumb, .thumbeb => module.addCSourceFiles(.{
            .root = webp.path("src/dsp"),
            .files = &.{ "alpha_processing_neon.c", "dec_neon.c", "filters_neon.c", "lossless_neon.c", "rescaler_neon.c", "upsampling_neon.c", "yuv_neon.c" },
            .flags = webp_flags,
        }),
        .x86, .x86_64 => module.addCSourceFiles(.{
            .root = webp.path("src/dsp"),
            .files = &.{
                "alpha_processing_sse2.c",  "dec_sse2.c",  "filters_sse2.c",   "lossless_sse2.c",    "rescaler_sse2.c", "upsampling_sse2.c", "yuv_sse2.c",
                "alpha_processing_sse41.c", "dec_sse41.c", "lossless_sse41.c", "upsampling_sse41.c", "yuv_sse41.c",     "lossless_avx2.c",
            },
            .flags = webp_flags,
        }),
        else => {},
    }
}

fn addStbDecoder(b: *Build, module: *Build.Module, target: Build.ResolvedTarget, legacy_flags: []const []const u8) void {
    addZlibNg(b, module, target);
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
    const api = std.mem.replaceOwned(u8, b.allocator, zlibSource(b, zlib, "zlib-ng.h.in"), "@ZLIB_SYMBOL_PREFIX@", "") catch @panic("OOM");
    _ = files.add("zlib-ng.h", b.fmt("#define UIDIFF_PNG_COMPRESSION_LEVEL {d}\n#define UIDIFF_ZLIB_CRC {d}\n{s}", .{
        png_compression_level, @intFromBool(zlibPngCrc(target)), api,
    }));
    const conf = zlibSource(b, zlib, "zconf-ng.h.in");
    _ = files.add("zconf-ng.h", if (target.result.os.tag == .windows) conf else std.mem.replaceOwned(
        u8,
        b.allocator,
        conf,
        "#ifdef HAVE_UNISTD_H",
        "#if 1",
    ) catch @panic("OOM"));
    _ = files.add("zlib_name_mangling-ng.h", zlibSource(b, zlib, "zlib_name_mangling.h.empty"));
    return files;
}

fn zlibSource(b: *Build, zlib: *Build.Dependency, name: []const u8) []u8 {
    b.dependOnFileContents(zlib.path(name));
    return zlib.builder.root.root_dir.handle.readFileAlloc(b.graph.io, b.pathJoin(&.{ zlib.builder.root.sub_path, name }), b.allocator, .limited(256 * 1024)) catch
        @panic("cannot read pinned zlib-ng source");
}

// Only the PNG writer initializes this compressor. Preserve the selected
// upstream level's tuning and drop the other compression strategies.
fn zlibDeflate(b: *Build, zlib: *Build.Dependency) Build.LazyPath {
    const source = zlibSource(b, zlib, "deflate.c");
    const table = std.mem.indexOf(u8, source, "static const config configuration_table[10] = {") orelse @panic("zlib-ng level table changed");
    const medium = std.mem.indexOfPos(u8, source, table, "#else\n/* 3 */") orelse @panic("zlib-ng medium strategy changed");
    const tag = b.fmt("/* {d} */ ", .{png_compression_level});
    const entry = (std.mem.indexOfPos(u8, source, medium, tag) orelse @panic("zlib-ng compression level missing")) + tag.len;
    const close = (std.mem.indexOfScalarPos(u8, source, entry, '}') orelse @panic("zlib-ng level entry changed")) + 1;
    const end = (std.mem.indexOfPos(u8, source, close, "}};") orelse @panic("zlib-ng level table changed")) + 3;
    if (std.mem.indexOf(u8, source[entry..close], "deflate_medium") == null) @panic("zlib-ng level no longer uses the medium strategy");
    var text = b.fmt("{s}static const config configuration = {s};{s}", .{ source[0..table], source[entry..close], source[end..] });
    const dispatch =
        \\s->level == 0 ? deflate_stored(s, flush) :
        \\                 s->strategy == Z_HUFFMAN_ONLY ? deflate_huff(s, flush) :
        \\                 s->strategy == Z_RLE ? deflate_rle(s, flush) :
        \\                 (*(configuration_table[s->level].func))(s, flush);
    ;
    for ([_][2][]const u8{
        .{ dispatch, "deflate_medium(s, flush);" },
        .{ "configuration_table[s->level]", "configuration" },
        .{ "configuration_table[level]", "configuration" },
        .{ "level < 0 || level > 9 || strategy < 0 || strategy > Z_FIXED", "level != UIDIFF_PNG_COMPRESSION_LEVEL || strategy != Z_DEFAULT_STRATEGY" },
    }) |change| {
        if (std.mem.indexOf(u8, text, change[0]) == null) @panic("zlib-ng compressor changed");
        text = std.mem.replaceOwned(u8, b.allocator, text, change[0], change[1]) catch @panic("OOM");
    }
    return b.addWriteFiles().add("deflate.c", text);
}

// Gzip is disabled, but the upstream dispatcher publishes gzip folding
// callbacks by default. Drop those references while preserving its ABI.
fn zlibDispatch(b: *Build, zlib: *Build.Dependency) Build.LazyPath {
    const source = zlibSource(b, zlib, "functable.c");
    const first = std.mem.indexOf(u8, source, "static void crc32_fold_stub(") orelse @panic("zlib-ng dispatch stubs changed");
    const last = std.mem.indexOfPos(u8, source, first, "static void inflate_fast_stub(") orelse @panic("zlib-ng dispatch stubs changed");
    const reachable = b.fmt("{s}{s}", .{ source[0..first], source[last..] });
    var result: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, reachable, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "ft.crc32_fold") != null or
            std.mem.indexOf(u8, line, "FUNCTABLE_VERIFY_ASSIGN(ft, crc32_fold") != null) continue;
        const trim = std.mem.trimStart(u8, line, " ");
        const kept = if (std.mem.startsWith(u8, trim, "crc32_fold")) "    NULL," else line;
        result.appendSlice(b.allocator, kept) catch @panic("OOM");
        result.append(b.allocator, '\n') catch @panic("OOM");
    }
    return b.addWriteFiles().add("functable.c", result.items);
}

fn zlibPngCrc(target: Build.ResolvedTarget) bool {
    return switch (target.result.cpu.arch) {
        .aarch64 => std.Target.aarch64.featureSetHas(target.result.cpu.features, .crc),
        .x86_64 => true,
        else => false,
    };
}

/// Builds the zlib stream and PNG checksum routines. Only x86 uses runtime dispatch.
fn addZlibNg(b: *Build, module: *Build.Module, target: Build.ResolvedTarget) void {
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
        "inftrees.c",
        "insert_string.c",
        "insert_string_roll.c",
        "trees.c",
        "zutil.c",
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
            common.appendSlice(b.allocator, &.{ "-DX86_FEATURES", "-DX86_SSE2", "-DX86_SSSE3", "-DX86_SSE41", "-DX86_SSE42", "-DX86_AVX2", "-DX86_PCLMULQDQ_CRC", "-DHAVE_CPUID_GNU", "-DX86_HAVE_XSAVE_INTRIN" }) catch @panic("OOM");
            const base = common.items;
            module.addCSourceFile(.{ .file = zlibDispatch(b, zlib), .flags = base });
            module.addCSourceFiles(.{ .root = zlib.path(""), .files = &(stream ++ scalar ++ .{ "crc32.c", "crc32_braid_comb.c", "cpu_features.c", "arch/x86/chunkset_sse2.c", "arch/x86/chorba_sse2.c", "arch/x86/compare256_sse2.c", "arch/x86/slide_hash_sse2.c" }), .flags = base });
            // Zig pins each object's CPU features, so -m flags cannot raise
            // them per file; each dispatch level is its own object instead.
            const levels = .{
                .{ "x86_features", std.Target.x86.featureSet(&.{.xsave}), &[_][]const u8{"arch/x86/x86_features.c"} },
                .{ "ssse3", std.Target.x86.featureSet(&.{.ssse3}), &[_][]const u8{ "arch/x86/adler32_ssse3.c", "arch/x86/chunkset_ssse3.c" } },
                .{ "sse41", std.Target.x86.featureSet(&.{.sse4_1}), &[_][]const u8{"arch/x86/chorba_sse41.c"} },
                .{ "sse42", std.Target.x86.featureSet(&.{.sse4_2}), &[_][]const u8{"arch/x86/adler32_sse42.c"} },
                .{ "pclmul", std.Target.x86.featureSet(&.{ .sse4_2, .pclmul }), &[_][]const u8{"arch/x86/crc32_pclmulqdq.c"} },
                .{ "avx2", std.Target.x86.featureSet(&.{ .avx2, .bmi2 }), &[_][]const u8{ "arch/x86/slide_hash_avx2.c", "arch/x86/chunkset_avx2.c", "arch/x86/compare256_avx2.c", "arch/x86/adler32_avx2.c" } },
            };
            inline for (levels) |level| {
                var query = target.query;
                query.cpu_features_add.addFeatureSet(level[1]);
                const part = b.createModule(.{
                    .target = b.resolveTargetQuery(query),
                    .optimize = module.optimize,
                    .link_libc = true,
                    .unwind_tables = module.unwind_tables,
                });
                part.addIncludePath(headers);
                part.addIncludePath(zlib.path(""));
                part.addCSourceFiles(.{ .root = zlib.path(""), .files = level[2], .flags = base });
                module.linkLibrary(b.addLibrary(.{ .name = "zlib-ng-" ++ level[0], .root_module = part }));
            }
        },
        else => {
            common.append(b.allocator, "-DDISABLE_RUNTIME_CPU_DETECTION") catch @panic("OOM");
            module.addCSourceFiles(.{ .root = zlib.path(""), .files = &(stream ++ scalar), .flags = common.items });
        },
    }
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
    const stb_c = b.addTranslateC(.{ .root_source_file = b.path("src/codec/stb.h"), .target = target, .optimize = codec_mode });
    stb_c.addIncludePath(stb.path(""));
    stb_c.defineCMacro("STBI_NO_STDIO", null);
    const webp_c = b.addTranslateC(.{ .root_source_file = webp.path("src/webp/decode.h"), .target = target, .optimize = codec_mode });
    const zlib_c = b.addTranslateC(.{ .root_source_file = zlibHeaders(b, target).getDirectory().path(b, "zlib-ng.h"), .target = target, .optimize = codec_mode });
    return .{
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

fn addTests(b: *Build, target: Build.ResolvedTarget, optimize: Optimize, decoders: Decoders, install_cli: *Build.Step.InstallArtifact, host_generator: *Build.Step.Compile) void {
    const uidiff = addCheckedLibrary(b, target, optimize, decoders);
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
        const tested = if (styled and optimize != .safe) addCheckedLibrary(b, target, .safe, decoders) else uidiff;
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
    const module = addCheckedLibrary(b, target, .debug, decoders);
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
    inline for (fixtures.all) |variant| {
        if (variant.change != .insert) continue;
        const run = b.addRunArtifact(bench);
        run.addArgs(&.{ variant.name, variant.path(.before, .png), variant.path(.after, .png), b.fmt("{d}", .{fixtures.scale}) });
        if (previous) |dependency| run.step.dependOn(dependency);
        previous = &run.step;
    }
    if (previous) |dependency| step.dependOn(dependency);
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
    addStbDecoder(b, codecs, target, &.{});
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
