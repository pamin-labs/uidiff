//! Runs the installed CLI against committed images and checks its process contract.
const std = @import("std");
const builtin = @import("builtin");
const uidiff = @import("uidiff");
const canvas = @import("uidiff_testing").canvas;
const png_format = @import("png_format");
const options = @import("e2e_options");
const fixtures = @import("fixtures");
const testing = std.testing;
const allocator = testing.allocator;
const report = uidiff.report;

const budget = std.Io.Limit.limited(4096);
const scale = std.fmt.comptimePrint("{d}", .{fixtures.scale});

const single_region_output = "1 region\n";
/// Pairs the batch test compares with single runs: a change, a move and no change.
const batch_specs = [_]fixtures.Change{ .edit, .insert, .identical };
/// Longer than any line the batch accepts, and than its input buffer.
const over_long_line_bytes = 1 << 20;

fn run(cwd: std.process.Child.Cwd, comptime argc: usize, args: [argc][]const u8) !std.process.RunResult {
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, options.executable, allocator);
    defer allocator.free(exe);
    return std.process.run(allocator, testing.io, .{
        .argv = &(.{exe} ++ args),
        .cwd = cwd,
        .stdout_limit = budget,
        .stderr_limit = budget,
    });
}

fn free(result: std.process.RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn status(result: std.process.RunResult, expected: u8) !void {
    try testing.expectEqual(std.process.Child.Term{ .exited = expected }, result.term);
}

fn failure(result: std.process.RunResult, expected: []const u8) !void {
    try status(result, 2);
    try testing.expectEqualStrings("", result.stdout);
    const stderr = std.mem.trimEnd(u8, result.stderr, "\r\n");
    try testing.expectEqualStrings(expected, stderr);
}

fn absolute(path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(testing.io, path, allocator);
}

test "generated pairs produce matching versioned reports in every encoding" {
    inline for (fixtures.all) |spec| {
        const bytes = @embedFile(comptime spec.expected()["tests/".len..]);
        const expected = try std.json.parseFromSlice(report.Report, allocator, bytes, .{ .ignore_unknown_fields = true });
        defer expected.deinit();
        inline for (comptime std.meta.tags(fixtures.Format)) |format| {
            errdefer std.debug.print("{s}.{s}\n", .{ spec.name, @tagName(format) });
            const result = try run(.inherit, 5, .{ spec.path(.before, format), spec.path(.after, format), "--scale", scale, "--json" });
            defer free(result);
            try status(result, if (expected.value.regions.len == 0) 0 else 1);
            try testing.expectEqualStrings("", result.stderr);
            const actual = try std.json.parseFromSlice(report.Report, allocator, result.stdout, .{ .ignore_unknown_fields = true });
            defer actual.deinit();
            try testing.expectEqualDeep(expected.value, actual.value);
        }
    }
}

test "the count output names one region in the singular" {
    const spec = comptime fixtures.find(.edit);
    const result = try run(.inherit, 4, .{ spec.path(.before, .png), spec.path(.after, .png), "--scale", scale });
    defer free(result);
    try status(result, 1);
    try testing.expectEqualStrings(single_region_output, result.stdout);
}

test "the CLI prints the package version from build.zig.zon" {
    const result = try run(.inherit, 1, .{"--version"});
    defer free(result);
    try status(result, 0);
    try testing.expectEqualStrings(options.version ++ "\n", result.stdout);
    try testing.expectEqualStrings("", result.stderr);
}

test "an annotated sheet is written atomically beside a normal report" {
    const spec = comptime fixtures.find(.edit);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const before = try absolute(spec.path(.before, .png));
    defer allocator.free(before);
    const after = try absolute(spec.path(.after, .png));
    defer allocator.free(after);
    {
        const result = try run(.{ .dir = tmp.dir }, 6, .{ before, after, "--scale", scale, "--annotate", "sheet.png" });
        defer free(result);
        try status(result, 1);
        try testing.expectEqualStrings(single_region_output, result.stdout);
    }
    const bytes = try tmp.dir.readFileAlloc(testing.io, "sheet.png", allocator, .limited(uidiff.max_encoded_bytes));
    defer allocator.free(bytes);
    try testing.expect(std.mem.startsWith(u8, bytes, png_format.signature));
    var chunks: png_format.Chunks = .{ .remaining = bytes[png_format.signature.len..] };
    while (chunks.nextChecksums()) |checksums| {
        try testing.expectEqual(checksums.computed, checksums.stored);
    }
    try testing.expectEqual(0, chunks.remaining.len);
    var sheet = try uidiff.decode(allocator, bytes);
    defer sheet.deinit();
    var source = try uidiff.decodeFile(testing.io, allocator, before);
    defer source.deinit();
    var target = try uidiff.decodeFile(testing.io, allocator, after);
    defer target.deinit();
    const changes = try uidiff.compare(allocator, .{ .before = source.image, .after = target.image }, .{ .scale = .{ .factor = fixtures.scale } });
    defer changes.deinit(allocator);
    const expected = try uidiff.renderSheet(allocator, .{ .before = source.image, .after = target.image }, changes.regions, changes.moves);
    defer expected.deinit(allocator);
    try testing.expectEqual(expected.width, sheet.image.width);
    try testing.expectEqual(expected.height, sheet.image.height);
    try testing.expectEqualSlices(uidiff.Pixel, expected.pixels, sheet.image.pixels);
    const result = try run(.{ .dir = tmp.dir }, 4, .{ before, after, "--annotate", "missing/sheet.png" });
    defer free(result);
    try failure(result, "error(uidiff): missing/sheet.png: FileNotFound");
    const directory = try run(.{ .dir = tmp.dir }, 4, .{ before, after, "--annotate", "." });
    defer free(directory);
    try failure(directory, "error(uidiff): .: IsDir");
}

test "annotation refuses input paths and preserves both captures" {
    const spec = comptime fixtures.find(.edit);
    const before = @embedFile(comptime spec.path(.before, .png)["tests/".len..]);
    const after = @embedFile(comptime spec.path(.after, .png)["tests/".len..]);
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "before.png", .data = before });
    try tmp.dir.writeFile(io, .{ .sub_path = "after.png", .data = after });
    const linked = linked: {
        tmp.dir.symLink(io, "after.png", "alias.png", .{}) catch |err| {
            if (builtin.os.tag == .windows and (err == error.PermissionDenied or err == error.AccessDenied)) break :linked false;
            return err;
        };
        break :linked true;
    };
    inline for (.{ "before.png", "./after.png", "alias.png" }) |sheet| {
        if (!std.mem.eql(u8, sheet, "alias.png") or linked) {
            const result = try run(.{ .dir = tmp.dir }, 4, .{ "before.png", "after.png", "--annotate", sheet });
            defer free(result);
            try failure(result, "error(uidiff): " ++ sheet ++ ": SheetIsInput");
            for ([_][]const u8{ "before.png", "after.png" }, [_][]const u8{ before, after }) |path, expected| {
                const actual = try tmp.dir.readFileAlloc(io, path, allocator, .limited(uidiff.max_encoded_bytes));
                defer allocator.free(actual);
                try testing.expectEqualSlices(u8, expected, actual);
            }
        }
    }
}

test "JSON includes moved device-pixel rows without changing version one" {
    const spec = fixtures.all[0];
    const result = try run(.inherit, 5, .{ spec.path(.before, .png), spec.path(.after, .png), "--scale", scale, "--json" });
    defer free(result);
    try status(result, 1);
    const actual = try std.json.parseFromSlice(report.Report, allocator, result.stdout, .{ .ignore_unknown_fields = true });
    defer actual.deinit();
    try testing.expectEqual(report.version, actual.value.version);
    try testing.expectEqual(@as(usize, 1), actual.value.regions.len);
    try testing.expectEqual(@as(usize, 1), actual.value.moves.len);
    const move = actual.value.moves[0];
    try testing.expectEqualDeep(uidiff.report.Move{
        .before = .{ .y = 320, .height = 864 },
        .after = .{ .y = 416, .height = 864 },
        .x = 128,
        .width = 616,
    }, move);
}

test "sheet encoding keeps nonopaque pixels and their RGB channels" {
    const pixels = [_]uidiff.Pixel{ .{ 60, 15, 230, 0 }, .{ 210, 120, 30, 99 } };
    const image: uidiff.Image = .{ .pixels = &pixels, .width = 2, .height = 1 };
    var encoded: std.Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    try uidiff.encodePng(allocator, image, &encoded.writer);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "input.png", .data = encoded.written() });
    const result = try run(.{ .dir = tmp.dir }, 4, .{ "input.png", "input.png", "--annotate", "sheet.png" });
    defer free(result);
    try status(result, 0);
    const bytes = try tmp.dir.readFileAlloc(testing.io, "sheet.png", allocator, .limited(uidiff.max_encoded_bytes));
    defer allocator.free(bytes);
    var decoded = try uidiff.decode(allocator, bytes);
    defer decoded.deinit();
    const expected = try uidiff.renderSheet(allocator, .{ .before = image, .after = image }, &.{}, &.{});
    defer expected.deinit(allocator);
    try testing.expectEqualSlices(uidiff.Pixel, expected.pixels, decoded.image.pixels);
}

test "a wide source uses the preview bounds and rejects a truncated input" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const width = 32_768;
    const pixels = try allocator.alloc(uidiff.Pixel, width);
    defer allocator.free(pixels);
    @memset(pixels, canvas.white);
    var encoded: std.Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    try uidiff.encodePng(allocator, .{ .width = width, .height = 1, .pixels = pixels }, &encoded.writer);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "wide.png", .data = encoded.written() });
    const preview = try run(.{ .dir = tmp.dir }, 4, .{ "wide.png", "wide.png", "--annotate", "sheet.png" });
    defer free(preview);
    try status(preview, 0);
    const sheet = try tmp.dir.readFileAlloc(testing.io, "sheet.png", allocator, .limited(1_000_000));
    defer allocator.free(sheet);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "wide.png", .data = encoded.written()[0..41] });

    const result = try run(.{ .dir = tmp.dir }, 4, .{ "wide.png", "wide.png", "--annotate", "sheet.png" });
    defer free(result);
    try failure(result, "error(uidiff): wide.png: InvalidImage");
    const invalid = try run(.{ .dir = tmp.dir }, 2, .{ "wide.png", "wide.png" });
    defer free(invalid);
    try failure(invalid, "error(uidiff): wide.png: InvalidImage");
    const directory = try run(.{ .dir = tmp.dir }, 4, .{ "wide.png", "wide.png", "--annotate", "." });
    defer free(directory);
    try failure(directory, "error(uidiff): .: IsDir");
    const preserved = try tmp.dir.readFileAlloc(testing.io, "sheet.png", allocator, .limited(1_000_000));
    defer allocator.free(preserved);
    try testing.expectEqualSlices(u8, sheet, preserved);
}

test "a small file claiming a huge 16-bit image is refused within its budget" {
    inline for (fixtures.claims) |claim| {
        const path = comptime claim.path();
        const result = try run(.inherit, 2, .{ path, path });
        defer free(result);
        try failure(result, "error(uidiff): " ++ path ++ ": ImageTooLarge");
    }
}

test "a batch answers each line as a single run would and continues past failures" {
    const Request = struct { before: []const u8, after: []const u8, scale: []const u8 = scale, annotate: ?[]const u8 = null };
    const exe = try absolute(options.executable);
    defer allocator.free(exe);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var input: std.Io.Writer.Allocating = .init(allocator);
    defer input.deinit();
    // Each pair's single-run line, as the batch must print it byte for byte.
    var expected: std.Io.Writer.Allocating = .init(allocator);
    defer expected.deinit();
    var inputs: [2 * batch_specs.len][:0]u8 = undefined;
    var resolved: usize = 0;
    defer for (inputs[0..resolved]) |path| allocator.free(path);
    inline for (batch_specs, 0..) |name, index| {
        const spec = comptime fixtures.find(name);
        inputs[2 * index] = try absolute(spec.path(.before, .png));
        resolved += 1;
        inputs[2 * index + 1] = try absolute(spec.path(.after, .png));
        resolved += 1;
        const before = inputs[2 * index];
        const after = inputs[2 * index + 1];
        const sheet: ?[]const u8 = if (index == 0) "single.png" else null;
        const single = if (sheet) |path|
            try run(.{ .dir = tmp.dir }, 7, .{ before, after, "--scale", scale, "--json", "--annotate", path })
        else
            try run(.{ .dir = tmp.dir }, 5, .{ before, after, "--scale", scale, "--json" });
        defer free(single);
        const code: u8 = switch (single.term) {
            .exited => |code| code,
            else => return error.TestUnexpectedResult,
        };
        try expected.writer.print("{{\"status\":{d},\"report\":{s}}}\n", .{ code, std.mem.trimEnd(u8, single.stdout, "\n") });
        try std.json.Stringify.value(Request{ .before = before, .after = after, .annotate = if (sheet != null) "batch.png" else null }, .{ .emit_null_optional_fields = false }, &input.writer);
        try input.writer.writeByte('\n');
    }
    try std.json.Stringify.value(Request{ .before = "missing.png", .after = inputs[1] }, .{}, &input.writer);
    try input.writer.writeByte('\n');
    try expected.writer.writeAll("{\"status\":2,\"error\":\"FileNotFound\",\"path\":\"missing.png\"}\n");
    try input.writer.splatByteAll('x', over_long_line_bytes);
    try input.writer.writeByte('\n');
    try expected.writer.writeAll("{\"status\":2,\"error\":\"LineTooLong\"}\n");

    var child = try std.process.spawn(testing.io, .{ .argv = &.{ exe, "--batch" }, .cwd = .{ .dir = tmp.dir }, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
    defer child.kill(testing.io);
    try child.stdin.?.writeStreamingAll(testing.io, input.written());
    child.stdin.?.close(testing.io);
    child.stdin = null;
    var buffer: [4096]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(testing.io, &buffer);
    const output = try reader.interface.allocRemaining(allocator, .limited(1 << 20));
    defer allocator.free(output);
    try testing.expectEqual(std.process.Child.Term{ .exited = 2 }, try child.wait(testing.io));
    try testing.expectEqualStrings(expected.written(), output);
    const single_sheet = try tmp.dir.readFileAlloc(testing.io, "single.png", allocator, .limited(uidiff.max_encoded_bytes));
    defer allocator.free(single_sheet);
    const batch_sheet = try tmp.dir.readFileAlloc(testing.io, "batch.png", allocator, .limited(uidiff.max_encoded_bytes));
    defer allocator.free(batch_sheet);
    try testing.expectEqualSlices(u8, single_sheet, batch_sheet);
}

test "a closed standard output is named and exits as a failure" {
    const spec = comptime fixtures.find(.edit);
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, options.executable, allocator);
    defer allocator.free(exe);
    var child = try std.process.spawn(testing.io, .{
        .argv = &.{ exe, spec.path(.before, .png), spec.path(.after, .png) },
        .stdin = .ignore,
        .stdout = .close,
        .stderr = .pipe,
    });
    defer child.kill(testing.io);
    var buffer: [256]u8 = undefined;
    var reader = child.stderr.?.readerStreaming(testing.io, &buffer);
    const stderr = try reader.interface.allocRemaining(allocator, budget);
    defer allocator.free(stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 2 }, try child.wait(testing.io));
    try testing.expect(std.mem.startsWith(u8, stderr, "error(uidiff): stdout: "));
}

test "unsupported file identifies just the failing path and error" {
    const path = "tests/fixtures/unsupported.txt";
    const result = try run(.inherit, 2, .{ comptime fixtures.find(.insert).path(.before, .png), path });
    defer free(result);
    try failure(result, "error(uidiff): " ++ path ++ ": UnsupportedImageFormat");
}

test "missing and sparse oversized files fail before decoding" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const result = try run(.{ .dir = tmp.dir }, 2, .{ "missing.png", "after.png" });
        defer free(result);
        try failure(result, "error(uidiff): missing.png: FileNotFound");
    }
    const name = "oversized.png";
    {
        var file = try tmp.dir.createFile(testing.io, name, .{});
        defer file.close(testing.io);
        try file.setLength(testing.io, uidiff.max_encoded_bytes + 1);
    }
    const result = try run(.{ .dir = tmp.dir }, 2, .{ name, "after.png" });
    defer free(result);
    try failure(result, "error(uidiff): oversized.png: ImageTooLarge");
}

test "malformed arguments and invalid scale return usage errors" {
    const usage = comptime std.mem.trimEnd(u8, options.usage, "\r\n");
    const cases = .{
        .{ .{ "before.png", "after.png", "--unknown" }, "unknown option: --unknown" },
        .{ .{ "before.png", "after.png", "--json", "--json" }, "option was repeated: --json" },
        .{ .{ "before.png", "after.png", "--scale" }, "option requires a value: --scale" },
        .{ .{ "before.png", "after.png", "--scale", "nan" }, "scale must be a positive decimal: nan" },
        .{ .{ "before.png", "after.png", "--scale", "0" }, "scale must be a positive decimal: 0" },
        .{ .{ "before.png", "after.png", "--annotate", "--json" }, "option requires a value: --annotate" },
        .{ .{ "--json", "before.png", "after.png" }, "options must follow both paths: --json" },
        .{ .{ "before.png", "--json", "after.png" }, "options must follow both paths: --json" },
        .{ .{ "--help", "x" }, "option must be used on its own: --help" },
        .{ .{"before.png"}, "expected before and after paths: before.png" },
    };
    inline for (cases) |case| {
        const result = try run(.inherit, case[0].len, case[0]);
        defer free(result);
        try failure(result, "uidiff: " ++ case[1] ++ "\n" ++ usage);
    }
}

test "help prints usage on stdout and exits successfully" {
    const result = try run(.inherit, 1, .{"--help"});
    defer free(result);
    try status(result, 0);
    try testing.expectEqualStrings(options.usage, result.stdout);
    try testing.expectEqualStrings("", result.stderr);
}

test "fractional scale rounds the padded box outward in device pixels" {
    const spec = comptime fixtures.find(.edit);
    const result = try run(.inherit, 5, .{ spec.path(.before, .png), spec.path(.after, .png), "--scale", "2.625", "--json" });
    defer free(result);
    try status(result, 1);
    const actual = try std.json.parseFromSlice(report.Report, allocator, result.stdout, .{ .ignore_unknown_fields = true });
    defer actual.deinit();
    const box: report.Box = .{ .x = 117, .y = 165, .width = 278, .height = 54 };
    try testing.expectEqualSlices(report.Region, &.{.{ .number = 1, .kind = .changed, .before = box, .after = box }}, actual.value.regions);
}

test "a PNG with a one-pixel diagonal exits with a change report" {
    const width = 200;
    const height = 200;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const pixels = try allocator.alloc(uidiff.Pixel, width * height);
    defer allocator.free(pixels);
    @memset(pixels, canvas.white);
    var encoded: std.Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    const image: uidiff.Image = .{ .width = width, .height = height, .pixels = pixels };
    try uidiff.encodePng(allocator, image, &encoded.writer);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "before.png", .data = encoded.written() });
    for (50..90) |p| pixels[p * width + p] = .{ 0, 0, 0, 255 };
    encoded.clearRetainingCapacity();
    try uidiff.encodePng(allocator, image, &encoded.writer);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "after.png", .data = encoded.written() });

    const result = try run(.{ .dir = tmp.dir }, 3, .{ "before.png", "after.png", "--json" });
    defer free(result);
    try status(result, 1);
    const actual = try std.json.parseFromSlice(report.Report, allocator, result.stdout, .{ .ignore_unknown_fields = true });
    defer actual.deinit();
    const expected: report.Box = .{ .x = 46, .y = 46, .width = 48, .height = 48 };
    try testing.expectEqualSlices(report.Region, &.{.{ .number = 1, .kind = .changed, .before = expected, .after = expected }}, actual.value.regions);
}

test {
    std.testing.refAllDecls(@This());
}
