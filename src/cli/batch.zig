//! `--batch`: reads one JSON request per input line and writes one JSON line
//! per request, in order, each flushed so a caller can pipeline.
const std = @import("std");
const uidiff = @import("uidiff");
const args = @import("args.zig");
const Status = @import("status.zig").Status;
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// One input line. Unknown fields are ignored.
const Request = struct {
    before: []const u8,
    after: []const u8,
    /// The `--scale` grammar; the single run's default when absent.
    scale: ?[]const u8 = null,
    /// Where to write the annotated sheet, if wanted.
    annotate: ?[]const u8 = null,
};

const RequestField = std.meta.FieldEnum(Request);

/// JSON already written by the report module, echoed unchanged so its bytes
/// equal the single run's.
const RawJson = struct {
    json: []const u8,

    pub fn jsonStringify(self: RawJson, writer: *std.json.Stringify) std.Io.Writer.Error!void {
        try writer.beginWriteRaw();
        try writer.writer.writeAll(self.json);
        writer.endWriteRaw();
    }
};

/// A compared pair: `report` is the single run's `--json` report.
const Reported = struct {
    status: u8,
    report: RawJson,
};

/// A pair that failed; `error` is the single run's error name.
const Failed = struct {
    status: u8 = @backingInt(Status.failed),
    @"error": []const u8,
    /// The input or sheet path that caused the failure, if one did.
    path: ?[]const u8 = null,
};

/// Why one line failed before or during its comparison.
const LineError = uidiff.FileCompareError || uidiff.report.PixelWriteError || error{ InvalidInput, InvalidScale, LineTooLong };

/// Failures that end the batch: reading its input or writing its output.
pub const Error = error{ReadFailed} || Io.Writer.Error || Allocator.Error;

/// The longest input line, without its newline; a longer one is answered
/// with `LineTooLong` and skipped.
pub const max_line_bytes = 64 * 1024;

const output_options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
const max_fuzz_line_bytes = 64;

/// Answers every line of input on output and returns the worst status.
/// input's buffer must hold a line of max_line_bytes and its newline.
pub fn run(io: Io, allocator: Allocator, input: *Io.Reader, output: *Io.Writer) Error!Status {
    std.debug.assert(input.buffer.len > max_line_bytes);
    var report: Io.Writer.Allocating = .init(allocator);
    defer report.deinit();
    var worst: Status = .unchanged;
    while (true) {
        // Request strings without escapes borrow the line; the rest, and the
        // scanner's nesting stack, live here until the line is answered. A
        // fresh arena per line costs one allocation and less code than reset.
        var strings: std.heap.ArenaAllocator = .init(allocator);
        defer strings.deinit();
        report.clearRetainingCapacity();
        var diagnostics: uidiff.Diagnostics = .{};
        const answered = if (input.takeDelimiter('\n')) |taken| answered: {
            const line = taken orelse break;
            if (line.len > max_line_bytes) break :answered error.LineTooLong;
            break :answered compareLine(io, allocator, strings.allocator(), line, &report.writer, &diagnostics);
        } else |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.StreamTooLong => answered: {
                try skipLine(input);
                break :answered error.LineTooLong;
            },
        };
        const status = if (answered) |status| reported: {
            try writeReported(output, status, report.written());
            break :reported status;
        } else |err| failed: {
            try writeFailed(output, err, diagnostics.path);
            break :failed .failed;
        };
        try output.flush();
        worst = worst.worst(status);
    }
    return worst;
}

/// Parses a request line the fuzzer builds; the CLI's one fuzz target calls it.
pub fn fuzzParseLine(_: void, smith: *std.testing.Smith) !void {
    var storage: [max_fuzz_line_bytes]u8 = undefined;
    const line = storage[0..smith.slice(&storage)];
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const command = parseLine(arena.allocator(), line) catch return;
    try std.testing.expect(command.options.compare.scale.isValid());
    try std.testing.expect(command.output == .json);
}

/// Parses a line into the command a single run would get. Strings borrow
/// line or live in arena.
fn parseLine(arena: Allocator, line: []const u8) error{ InvalidInput, InvalidScale, OutOfMemory }!args.Command {
    var scanner: std.json.Scanner = .initCompleteInput(arena, line);
    const request = readRequest(arena, &scanner) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidInput,
    };
    var command: args.Command = .{ .paths = .{ .before = request.before, .after = request.after }, .output = .json };
    if (request.annotate) |path| {
        // The single run refuses an empty --annotate value too.
        if (path.len == 0) return error.InvalidInput;
        command.paths.annotate = path;
    }
    if (request.scale) |text| command.options.compare.scale = args.parseScale(text) orelse return error.InvalidScale;
    return command;
}

/// Reads one object of string fields into a Request, skipping unknown
/// fields. Driving the scanner directly keeps std.json's generic parser,
/// and the number parsing it brings for byte arrays, out of the binary.
fn readRequest(arena: Allocator, scanner: *std.json.Scanner) !Request {
    var values: std.EnumArray(RequestField, ?[]const u8) = .initFill(null);
    var seen: std.EnumSet(RequestField) = .empty;
    if (try scanner.next() != .object_begin) return error.InvalidInput;
    while (true) {
        const name = switch (try scanner.nextAlloc(arena, .alloc_if_needed)) {
            .object_end => break,
            .string, .allocated_string => |name| name,
            else => return error.InvalidInput,
        };
        const field = requestField(name) orelse {
            try scanner.skipValue();
            continue;
        };
        if (seen.contains(field)) return error.InvalidInput;
        seen.insert(field);
        // null reads as absent, as std.json reads it into an optional field.
        values.set(field, switch (try scanner.nextAlloc(arena, .alloc_if_needed)) {
            .string, .allocated_string => |text| text,
            .null => null,
            else => return error.InvalidInput,
        });
    }
    if (try scanner.next() != .end_of_document) return error.InvalidInput;
    return .{
        .before = values.get(.before) orelse return error.InvalidInput,
        .after = values.get(.after) orelse return error.InvalidInput,
        .scale = values.get(.scale),
        .annotate = values.get(.annotate),
    };
}

/// A plain scan over four names, as args.Flag does.
fn requestField(name: []const u8) ?RequestField {
    for (std.enums.values(RequestField), std.meta.fieldNames(Request)) |field, field_name| {
        if (std.mem.eql(u8, field_name, name)) return field;
    }
    return null;
}

/// Compares one line's pair and writes its report to report.
fn compareLine(io: Io, allocator: Allocator, arena: Allocator, line: []const u8, report: *Io.Writer, diagnostics: *uidiff.Diagnostics) LineError!Status {
    const command = try parseLine(arena, line);
    const result = try uidiff.compareFiles(io, allocator, command.paths, command.options, diagnostics);
    defer result.deinit(allocator);
    uidiff.report.writeWholePixels(report, result.regions, result.canvas(), result.moves) catch |err| switch (err) {
        // The report buffer fails only when it cannot grow.
        error.WriteFailed => return error.OutOfMemory,
        error.InvalidRegionBox => return error.InvalidRegionBox,
    };
    return Status.of(result);
}

/// Discards the rest of an over-long line.
fn skipLine(input: *Io.Reader) error{ReadFailed}!void {
    _ = input.discardDelimiterInclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return,
        error.ReadFailed => return error.ReadFailed,
    };
}

fn writeReported(output: *Io.Writer, status: Status, report: []const u8) Io.Writer.Error!void {
    // The single run ends its report with a newline; the batch line ends after it.
    std.debug.assert(std.mem.endsWith(u8, report, "\n"));
    try std.json.Stringify.value(Reported{ .status = @backingInt(status), .report = .{ .json = report[0 .. report.len - 1] } }, output_options, output);
    try output.writeByte('\n');
}

noinline fn writeFailed(output: *Io.Writer, err: LineError, path: ?[]const u8) Io.Writer.Error!void {
    @branchHint(.cold);
    try std.json.Stringify.value(Failed{ .@"error" = @errorName(err), .path = path }, output_options, output);
    try output.writeByte('\n');
}

fn expectLine(comptime expected: []const u8, line: []const u8) !void {
    try std.testing.expectEqualStrings(expected ++ "\n", line);
}

test "a request line becomes the single run's command" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const full = try parseLine(arena.allocator(),
        \\{"before":"a.png","after":"b\u002epng","scale":"1.5","annotate":"sheet.png","note":[1]}
    );
    try std.testing.expectEqualStrings("a.png", full.paths.before);
    try std.testing.expectEqualStrings("b.png", full.paths.after);
    try std.testing.expectEqualStrings("sheet.png", full.paths.annotate.?);
    try std.testing.expectEqual(@as(f64, 1.5), full.options.compare.scale.factor);
    try std.testing.expect(full.output == .json);
    const plain = try parseLine(arena.allocator(), "{\"before\":\"a\",\"after\":\"b\",\"annotate\":null}\r");
    const defaults: args.Command = .{ .paths = .{ .before = "a", .after = "b" } };
    try std.testing.expectEqual(defaults.options.compare.scale.factor, plain.options.compare.scale.factor);
    try std.testing.expectEqual(@as(?[]const u8, null), plain.paths.annotate);
}

test "malformed lines are refused with a code" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "",
        "a.png\tb.png",
        "{\"before\":\"a\"}",
        "{\"before\":\"a\",\"after\":2}",
        "{\"before\":\"a\",\"after\":null}",
        "{\"before\":\"a\",\"after\":\"b\",\"scale\":null,\"scale\":\"2\"}",
        "{\"before\":\"a\",\"after\":\"b\",\"after\":\"c\"}",
        "{\"before\":\"a\",\"after\":\"b\",\"annotate\":\"\"}",
        "{\"before\":\"a\",\"after\":\"b\"} {}",
    }) |line| try std.testing.expectError(error.InvalidInput, parseLine(arena.allocator(), line));
    for ([_][]const u8{ "", "0", "1e2", "2x" }) |scale| {
        const line = try std.fmt.allocPrint(arena.allocator(), "{{\"before\":\"a\",\"after\":\"b\",\"scale\":\"{s}\"}}", .{scale});
        try std.testing.expectError(error.InvalidScale, parseLine(arena.allocator(), line));
    }
}

test "answer lines carry the status, the raw report or the error and path" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeReported(&output.writer, .changed, "{\"version\":1}\n");
    try expectLine("{\"status\":1,\"report\":{\"version\":1}}", output.written());
    output.clearRetainingCapacity();
    try writeFailed(&output.writer, error.FileNotFound, "dir/\"a\".png");
    try expectLine("{\"status\":2,\"error\":\"FileNotFound\",\"path\":\"dir/\\\"a\\\".png\"}", output.written());
    output.clearRetainingCapacity();
    try writeFailed(&output.writer, error.InvalidInput, null);
    try expectLine("{\"status\":2,\"error\":\"InvalidInput\"}", output.written());
}

test "a batch answers every line in order and exits with the worst status" {
    const long: [max_line_bytes + 1]u8 = @splat('x');
    const text = "{\"before\":\"missing-before.png\",\"after\":\"b.png\"}\n" ++ long ++ "\nnot json\n{\"before\":\"a\",\"after\":\"b\",\"scale\":\"0\"}";
    // A fixed reader buffers all of text, so the long line arrives whole and
    // is refused by its length; the e2e test sends one longer than the buffer.
    var input: Io.Reader = .fixed(text);
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const status = try run(std.testing.io, std.testing.allocator, &input, &output.writer);
    try std.testing.expectEqual(Status.failed, status);
    try expectLine(
        \\{"status":2,"error":"FileNotFound","path":"missing-before.png"}
        \\{"status":2,"error":"LineTooLong"}
        \\{"status":2,"error":"InvalidInput"}
        \\{"status":2,"error":"InvalidScale"}
    , output.written());
}

test {
    std.testing.refAllDecls(@This());
}
