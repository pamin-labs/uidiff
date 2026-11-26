//! Builds the CLI, codec bindings, tests, fixtures, benchmark and size check.
const std = @import("std");
const fixtures = @import("tests/fixtures.zig");
const codecs = @import("build/codecs.zig");
const Optimize = std.builtin.Optimize;
const Build = std.Build;
const Decoders = codecs.Decoders;
const CodecBuild = codecs.CodecBuild;
const X86Simd = codecs.X86Simd;

// The shipped Zig binary retains runtime safety checks. The C decoders
// run with UBSan in the checked test build and in fuzzing.
const shipped_mode: Optimize = .safe;
/// The shipped CLI's size budget for every CI target. Run zig build size
/// with -Dtarget to measure a specific binary.
const max_cli_bytes = 1_200_000;
const cli_name = "uidiff";
const cli_source = "src/cli.zig";
const fuzz_directory = "tests/fuzz";
const styled_sheet_fuzz_source = fuzz_directory ++ "/sheet.zig";
// The self-hosted x86_64 backend used by Debug on Linux does not emit the
// fuzzer's PC tables. The coverage runners need LLVM even in Debug.
const fuzz_use_llvm = true;
/// Tests that read source files outside the compiler's import graph.
const source_tests = [_][]const u8{ "tests/source/layers.zig", "tests/source/order.zig" };

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
    const decoders = codecs.addDecoders(b, target);
    const lib = libraryOptions(b, target, optimize, decoders);
    const uidiff = b.addModule("uidiff", lib);
    codecs.linkShippedCodecs(b, uidiff, target, x86_simd, .shipped);
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
    if (cli_mode == .shipped_lto) codecs.linkShippedCodecs(b, cli_library, target, x86_simd, cli_mode);

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
    const host_generator = if (target.query.isNative()) generator else fixtureGenerator(b, b.graph.host, codecs.addDecoders(b, b.graph.host));
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
            .{ .name = "png_format", .module = decoders.png_format },
            .{ .name = "required_test_options", .module = defaults.createModule() },
        }) catch @panic("OOM"),
    };
}

fn addCheckedLibrary(b: *Build, target: Build.ResolvedTarget, optimize: Optimize, decoders: Decoders, x86_simd: X86Simd) *Build.Module {
    const module = b.createModule(libraryOptions(b, target, optimize, decoders));
    codecs.addDecoderSources(b, module, target, .checked, x86_simd);
    module.addImport("uidiff_test_canvas", b.createModule(.{
        .root_source_file = b.path("src/testing/canvas.zig"),
        .target = target,
        .optimize = optimize,
    }));
    return module;
}

fn addSizeCheck(b: *Build, install_cli: *Build.Step.InstallArtifact) void {
    const checker = b.addExecutable(.{ .name = "uidiff-size", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/size.zig"),
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
    const fixtures_module = b.createModule(.{ .root_source_file = b.path("tests/fixtures.zig"), .target = target, .optimize = optimize });
    const uidiff_testing = addTestingModule(b, uidiff);
    _ = addE2e(b, target, optimize, uidiff, uidiff_testing, fixtures_module, install_cli, version);
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
                .{ .name = "fixtures", .module = fixtures_module },
            },
        });
        if (index == fuzz_sources.len) test_module.addImport("png_format", decoders.png_format);
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
        .root_source_file = b.path("tools/size.zig"),
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
    const fallback = addCheckedLibrary(b, baseline, optimize, codecs.addDecoders(b, baseline), .without_avx2);
    addRequiredTest(b, fallback, "test-x86-fallback", "Check PNG dictionary wrapping without AVX2", "streaming PNG matches procedural RGBA across dictionary wraps");
}

fn addRequiredTest(b: *Build, library: *Build.Module, name: []const u8, description: []const u8, filter: []const u8) void {
    const options = b.addOptions();
    options.addOption([]const u8, "filter", filter);
    library.addImport("required_test_options", options.createModule());
    const filters = b.allocator.dupe([]const u8, &.{ filter, "required test selection" }) catch @panic("OOM");
    b.step(name, description).dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = library, .filters = filters })).step);
}

fn addE2e(b: *Build, target: Build.ResolvedTarget, optimize: Optimize, uidiff: *Build.Module, uidiff_testing: *Build.Module, fixtures_module: *Build.Module, install_cli: *Build.Step.InstallArtifact, version: []const u8) *Build.Step {
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
                .{ .name = "fixtures", .module = fixtures_module },
                .{ .name = "e2e_options", .module = options.createModule() },
                .{ .name = "png_format", .module = uidiff.import_table.get("png_format").? },
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
            if (scale) |scale_text| run.addArg(scale_text);
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
    const library = b.createModule(libraryOptions(b, target, .safe, decoders));
    const module = codecs.fixtureModule(b, target, library, decoders, b.path("tools/fixtures/generate.zig"), b.path("tools/fixtures/stb_write.c"));
    module.addImport("fixture_cases", b.createModule(.{ .root_source_file = b.path("tests/fixtures/cases.zig") }));
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
    const module = codecs.jpegFixtureModule(b, b.path("tools/fixtures/jpeg_generate.zig"));
    module.addImport("fixture_jpeg", b.createModule(.{ .root_source_file = b.path("tests/fixtures/jpeg.zig") }));
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
