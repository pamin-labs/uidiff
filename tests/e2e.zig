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

/// One output line, decoded into the report's own types.
const Line = struct {
    status: u8,
    report: ?report.Report = null,
    @"error": ?[]const u8 = null,
    path: ?[]const u8 = null,
};

const budget = std.Io.Limit.limited(4096);
const scale = std.fmt.comptimePrint("{d}", .{fixtures.scale});

/// Pairs the grouped run compares with single runs: a change, a move and no change.
const group_specs = [_]fixtures.Change{ .edit, .insert, .identical };
/// Longer than any request line accepted, and than its input buffer.
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

/// Decodes a run's one output line; the caller deinits it.
fn onlyLine(result: std.process.RunResult) !std.json.Parsed(Line) {
    try testing.expectEqualStrings("", result.stderr);
    const end = std.mem.indexOfScalar(u8, result.stdout, '\n') orelse return error.TestUnexpectedResult;
    try testing.expectEqual(result.stdout.len, end + 1);
    return std.json.parseFromSlice(Line, allocator, result.stdout, .{ .ignore_unknown_fields = true });
}

/// Decodes a successful run's one report and checks its status.
fn onlyReport(result: std.process.RunResult, expected_status: u8) !std.json.Parsed(Line) {
    try status(result, expected_status);
    const line = try onlyLine(result);
    errdefer line.deinit();
    try testing.expectEqual(expected_status, line.value.status);
    try testing.expect(line.value.report != null);
    return line;
}

/// Checks a run that answered its one request with an error line.
fn failure(result: std.process.RunResult, expected_error: []const u8, expected_path: ?[]const u8) !void {
    try status(result, 2);
    const line = try onlyLine(result);
    defer line.deinit();
    try testing.expectEqualDeep(Line{ .status = 2, .@"error" = expected_error, .path = expected_path }, line.value);
}

/// Checks a usage error: the message and usage on stderr, no output line.
fn usageFailure(result: std.process.RunResult, expected: []const u8) !void {
    try status(result, 2);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expectEqualStrings(expected, std.mem.trimEnd(u8, result.stderr, "\r\n"));
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
            const result = try run(.inherit, 4, .{ spec.path(.before, format), spec.path(.after, format), "--scale", scale });
            defer free(result);
            const actual = try onlyReport(result, if (expected.value.regions.len == 0) 0 else 1);
            defer actual.deinit();
            try testing.expectEqualDeep(expected.value, actual.value.report.?);
        }
    }
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
        const line = try onlyReport(result, 1);
        defer line.deinit();
        try testing.expectEqual(@as(usize, 1), line.value.report.?.regions.len);
    }
    const bytes = try tmp.dir.readFileAlloc(testing.io, "sheet.png", allocator, .limited(uidiff.max_encoded_bytes));
    defer allocator.free(bytes);
    try testing.expect(std.mem.startsWith(u8, bytes, png_format.signature));
    var chunks: png_format.Chunks = .{ .remaining = bytes[png_format.signature.len..] };
    while (chunks.nextChecksums()) |checksums| {
        try testing.expectEqual(checksums.computed, checksums.stored);
    }
    try testing.expectEqual(0, chunks.remaining.len);
    var sheet = try uidiff.decode(allocator, bytes, uidiff.max_decode_bytes);
    defer sheet.deinit();
    var source = try uidiff.decodeFile(testing.io, allocator, before, uidiff.max_decode_bytes);
    defer source.deinit();
    var target = try uidiff.decodeFile(testing.io, allocator, after, uidiff.max_decode_bytes);
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
    try failure(result, "FileNotFound", "missing/sheet.png");
    const directory = try run(.{ .dir = tmp.dir }, 4, .{ before, after, "--annotate", "." });
    defer free(directory);
    try failure(directory, "IsDir", ".");
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
            try failure(result, "SheetIsInput", sheet);
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
    const result = try run(.inherit, 4, .{ spec.path(.before, .png), spec.path(.after, .png), "--scale", scale });
    defer free(result);
    const line = try onlyReport(result, 1);
    defer line.deinit();
    const actual = line.value.report.?;
    try testing.expectEqual(report.version, actual.version);
    try testing.expectEqual(@as(usize, 1), actual.regions.len);
    try testing.expectEqual(@as(usize, 1), actual.moves.len);
    const move = actual.moves[0];
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
    var decoded = try uidiff.decode(allocator, bytes, uidiff.max_decode_bytes);
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
    try failure(result, "InvalidImage", "wide.png");
    const invalid = try run(.{ .dir = tmp.dir }, 2, .{ "wide.png", "wide.png" });
    defer free(invalid);
    try failure(invalid, "InvalidImage", "wide.png");
    const directory = try run(.{ .dir = tmp.dir }, 4, .{ "wide.png", "wide.png", "--annotate", "." });
    defer free(directory);
    try failure(directory, "IsDir", ".");
    const preserved = try tmp.dir.readFileAlloc(testing.io, "sheet.png", allocator, .limited(1_000_000));
    defer allocator.free(preserved);
    try testing.expectEqualSlices(u8, sheet, preserved);
}

test "a small file claiming a huge 16-bit image is refused within its budget" {
    inline for (fixtures.claims) |claim| {
        const path = comptime claim.path();
        const result = try run(.inherit, 2, .{ path, path });
        defer free(result);
        try failure(result, "ImageTooLarge", path);
    }
}

test "groups and request lines are answered as one run per pair would be" {
    const Request = struct { before: []const u8, after: []const u8, scale: ?[]const u8 = scale, annotate: ?[]const u8 = null };
    const exe = try absolute(options.executable);
    defer allocator.free(exe);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var input: std.Io.Writer.Allocating = .init(allocator);
    defer input.deinit();
    // Each pair's own run's line, as every grouped run must print it byte for byte.
    var expected: std.Io.Writer.Allocating = .init(allocator);
    defer expected.deinit();
    var inputs: [2 * group_specs.len][:0]u8 = undefined;
    var resolved: usize = 0;
    defer for (inputs[0..resolved]) |path| allocator.free(path);
    var worst: u8 = 0;
    inline for (group_specs, 0..) |name, index| {
        const spec = comptime fixtures.find(name);
        inputs[2 * index] = try absolute(spec.path(.before, .png));
        resolved += 1;
        inputs[2 * index + 1] = try absolute(spec.path(.after, .png));
        resolved += 1;
        const before = inputs[2 * index];
        const after = inputs[2 * index + 1];
        const annotated = index == 0;
        // The last group takes no option, so it shows none leaks from the one before.
        const plain = index == group_specs.len - 1;
        const single = if (annotated)
            try run(.{ .dir = tmp.dir }, 6, .{ before, after, "--scale", scale, "--annotate", "single.png" })
        else if (plain)
            try run(.{ .dir = tmp.dir }, 2, .{ before, after })
        else
            try run(.{ .dir = tmp.dir }, 4, .{ before, after, "--scale", scale });
        defer free(single);
        const code: u8 = switch (single.term) {
            .exited => |code| code,
            else => return error.TestUnexpectedResult,
        };
        worst = @max(worst, code);
        try expected.writer.writeAll(single.stdout);
        try std.json.Stringify.value(Request{ .before = before, .after = after, .scale = if (plain) null else scale, .annotate = if (annotated) "stdin.png" else null }, .{ .emit_null_optional_fields = false }, &input.writer);
        try input.writer.writeByte('\n');
    }
    const single_sheet = try tmp.dir.readFileAlloc(testing.io, "single.png", allocator, .limited(uidiff.max_encoded_bytes));
    defer allocator.free(single_sheet);

    {
        const grouped = try run(.{ .dir = tmp.dir }, 12, .{
            inputs[0], inputs[1], "--scale", scale, "--annotate", "grouped.png",
            inputs[2], inputs[3], "--scale", scale, inputs[4],    inputs[5],
        });
        defer free(grouped);
        try status(grouped, worst);
        try testing.expectEqualStrings("", grouped.stderr);
        try testing.expectEqualStrings(expected.written(), grouped.stdout);
        const sheet = try tmp.dir.readFileAlloc(testing.io, "grouped.png", allocator, .limited(uidiff.max_encoded_bytes));
        defer allocator.free(sheet);
        try testing.expectEqualSlices(u8, single_sheet, sheet);
    }

    try std.json.Stringify.value(Request{ .before = "missing.png", .after = inputs[1] }, .{}, &input.writer);
    try input.writer.writeByte('\n');
    try expected.writer.writeAll("{\"status\":2,\"error\":\"FileNotFound\",\"path\":\"missing.png\"}\n");
    try input.writer.splatByteAll('x', over_long_line_bytes);
    try input.writer.writeByte('\n');
    try expected.writer.writeAll("{\"status\":2,\"error\":\"LineTooLong\"}\n");

    var child = try std.process.spawn(testing.io, .{ .argv = &.{exe}, .cwd = .{ .dir = tmp.dir }, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
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
    const stdin_sheet = try tmp.dir.readFileAlloc(testing.io, "stdin.png", allocator, .limited(uidiff.max_encoded_bytes));
    defer allocator.free(stdin_sheet);
    try testing.expectEqualSlices(u8, single_sheet, stdin_sheet);
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
    try failure(result, "UnsupportedImageFormat", path);
}

test "missing and sparse oversized files fail before decoding" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const result = try run(.{ .dir = tmp.dir }, 2, .{ "missing.png", "after.png" });
        defer free(result);
        try failure(result, "FileNotFound", "missing.png");
    }
    const name = "oversized.png";
    {
        var file = try tmp.dir.createFile(testing.io, name, .{});
        defer file.close(testing.io);
        try file.setLength(testing.io, uidiff.max_encoded_bytes + 1);
    }
    const result = try run(.{ .dir = tmp.dir }, 2, .{ name, "after.png" });
    defer free(result);
    try failure(result, "ImageTooLarge", "oversized.png");
}

test "malformed arguments and invalid scale return usage errors" {
    const usage = comptime std.mem.trimEnd(u8, options.usage, "\r\n");
    const cases = .{
        .{ .{ "before.png", "after.png", "--unknown" }, "unknown option: --unknown" },
        .{ .{ "before.png", "after.png", "--scale", "2", "--scale", "2" }, "option was repeated: --scale" },
        .{ .{ "before.png", "after.png", "--scale" }, "option requires a value: --scale" },
        .{ .{ "before.png", "after.png", "--scale", "nan" }, "scale must be a positive decimal: nan" },
        .{ .{ "before.png", "after.png", "--scale", "0" }, "scale must be a positive decimal: 0" },
        .{ .{ "before.png", "after.png", "--annotate", "--scale" }, "option requires a value: --annotate" },
        .{ .{ "--scale", "2", "before.png", "after.png" }, "options must follow both paths: --scale" },
        .{ .{ "before.png", "--annotate", "sheet.png", "after.png" }, "options must follow both paths: --annotate" },
        .{ .{ "before.png", "after.png", "--json" }, "unknown option: --json" },
        .{ .{"--batch"}, "unknown option: --batch" },
        .{ .{ "--help", "x" }, "option must be used on its own: --help" },
        .{ .{"before.png"}, "expected before and after paths: before.png" },
        .{ .{ "a.png", "b.png", "c.png" }, "expected before and after paths: c.png" },
    };
    inline for (cases) |case| {
        const result = try run(.inherit, case[0].len, case[0]);
        defer free(result);
        try usageFailure(result, "uidiff: " ++ case[1] ++ "\n" ++ usage);
    }
}

test "no arguments with stdin not a terminal reads requests until its end" {
    const exe = try absolute(options.executable);
    defer allocator.free(exe);
    var child = try std.process.spawn(testing.io, .{ .argv = &.{exe}, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe });
    defer child.kill(testing.io);
    child.stdin.?.close(testing.io);
    child.stdin = null;
    var buffer: [256]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(testing.io, &buffer);
    const output = try reader.interface.allocRemaining(allocator, budget);
    defer allocator.free(output);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(testing.io));
    try testing.expectEqualStrings("", output);
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
    const result = try run(.inherit, 4, .{ spec.path(.before, .png), spec.path(.after, .png), "--scale", "2.625" });
    defer free(result);
    const line = try onlyReport(result, 1);
    defer line.deinit();
    const box: report.Box = .{ .x = 117, .y = 165, .width = 278, .height = 54 };
    try testing.expectEqualSlices(report.Region, &.{.{ .number = 1, .kind = .changed, .before = box, .after = box }}, line.value.report.?.regions);
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

    const result = try run(.{ .dir = tmp.dir }, 2, .{ "before.png", "after.png" });
    defer free(result);
    const line = try onlyReport(result, 1);
    defer line.deinit();
    const expected: report.Box = .{ .x = 46, .y = 46, .width = 48, .height = 48 };
    try testing.expectEqualSlices(report.Region, &.{.{ .number = 1, .kind = .changed, .before = expected, .after = expected }}, line.value.report.?.regions);
}

test {
    std.testing.refAllDecls(@This());
}
