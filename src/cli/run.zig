//! Runs each request, from the command line or from standard input, and
//! writes one JSON line per request, in order, each flushed so a caller can
//! pipeline.
const std = @import("std");
const builtin = @import("builtin");
const uidiff = @import("uidiff");
const request = @import("request.zig");
const reuse = @import("reuse.zig");
const Status = @import("status.zig").Status;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Request = request.Request;

/// JSON already written by the report module, echoed unchanged so its bytes
/// equal `uidiff.report.write`'s.
const RawJson = struct {
    json: []const u8,

    pub fn jsonStringify(self: RawJson, writer: *std.json.Stringify) std.Io.Writer.Error!void {
        try writer.beginWriteRaw();
        try writer.writer.writeAll(self.json);
        writer.endWriteRaw();
    }
};

/// A compared pair and its report.
const Reported = struct {
    status: u8,
    report: RawJson,
};

/// A request that failed; `error` is the library's or the request line's
/// error name.
const Failed = struct {
    status: u8 = @backingInt(Status.failed),
    @"error": []const u8,
    /// The input or sheet path that caused the failure, if one did.
    path: ?[]const u8 = null,
};

/// Why one request failed before or during its comparison.
const RequestError = uidiff.FileCompareError || uidiff.report.WriteError || request.ParseError || error{LineTooLong};

/// Failures that end a run of input lines: reading the input or writing
/// the output. A run of listed requests fails only on output.
pub const Error = error{ReadFailed} || Io.Writer.Error;

/// Writes one line per request and keeps the worst status. Its report
/// buffer is reused from request to request.
const Answers = struct {
    io: Io,
    allocator: Allocator,
    output: *Io.Writer,
    report: Io.Writer.Allocating,
    worst: Status = .unchanged,

    fn init(io: Io, allocator: Allocator, output: *Io.Writer) Answers {
        return .{ .io = io, .allocator = allocator, .output = output, .report = .init(allocator) };
    }

    fn deinit(self: *Answers) void {
        self.report.deinit();
    }

    /// Compares one request, or reports why it has none, and writes its line.
    fn answer(self: *Answers, parsed: RequestError!Request) Io.Writer.Error!void {
        self.report.clearRetainingCapacity();
        var diagnostics: uidiff.Diagnostics = .{};
        const status = if (self.compare(parsed, &diagnostics)) |status| reported: {
            try writeReported(self.output, status, self.report.written());
            break :reported status;
        } else |err| failed: {
            try writeFailed(self.output, err, diagnostics.path);
            break :failed .failed;
        };
        try self.output.flush();
        self.worst = self.worst.worst(status);
    }

    /// Compares one request's pair and writes its report to the report buffer.
    fn compare(self: *Answers, parsed: RequestError!Request, diagnostics: *uidiff.Diagnostics) RequestError!Status {
        const item = try parsed;
        const result = try uidiff.compareFiles(self.io, self.allocator, item.paths, item.options, diagnostics);
        defer result.deinit(self.allocator);
        uidiff.report.write(result.regions, result.canvas(), result.moves, &self.report.writer) catch |err| switch (err) {
            // The report buffer fails only when it cannot grow.
            error.WriteFailed => return error.OutOfMemory,
            error.InvalidRegionBox, error.InvalidRegionNumber, error.InvalidMove => |invalid| return invalid,
        };
        return Status.of(result);
    }
};

/// The longest input line, without its newline; a longer one is answered
/// with `LineTooLong` and skipped.
pub const max_line_bytes = 64 * 1024;

const output_options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };

/// Answers every request on output, comparing through blocks, and returns
/// the worst status.
pub fn requests(io: Io, blocks: *reuse.LargeBlocks, list: []const Request, output: *Io.Writer) Io.Writer.Error!Status {
    var answers: Answers = .init(io, blocks.allocator(), output);
    defer answers.deinit();
    for (list, 0..) |item, index| {
        if (index == list.len - 1) blocks.startLast();
        try answers.answer(item);
    }
    return answers.worst;
}

/// Answers every line of input on output, comparing through blocks, and
/// returns the worst status. input's buffer must hold a line of
/// max_line_bytes and its newline.
pub fn lines(io: Io, blocks: *reuse.LargeBlocks, file: *Io.File.Reader, output: *Io.Writer) Error!Status {
    const input = &file.interface;
    std.debug.assert(input.buffer.len > max_line_bytes);
    const allocator = blocks.allocator();
    var answers: Answers = .init(io, allocator, output);
    defer answers.deinit();
    while (true) {
        // Request strings and the scanner's nesting stack live here until the
        // line is answered. A fresh arena per line costs one allocation and
        // less code than reset.
        var strings: std.heap.ArenaAllocator = .init(allocator);
        defer strings.deinit();
        const parsed: RequestError!Request = if (input.takeDelimiter('\n')) |taken| parsed: {
            const line = taken orelse break;
            if (line.len > max_line_bytes) break :parsed error.LineTooLong;
            break :parsed request.parseLine(strings.allocator(), line);
        } else |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.StreamTooLong => parsed: {
                try skipLine(input);
                break :parsed error.LineTooLong;
            },
        };
        // The request does not borrow the line, so probing may refill the buffer.
        if (atEnd(file)) blocks.startLast();
        try answers.answer(parsed);
    }
    return answers.worst;
}

/// Whether input has no line left, known without waiting: nothing is
/// buffered, the file is ready to read, and reading it gives its end. A pipe
/// still open with nothing written counts as more to come, as does a pipe on
/// Windows, where readiness is not checked. A failed read counts as more to
/// come too: the next line's read meets the failure and reports it.
fn atEnd(file: *Io.File.Reader) bool {
    if (file.interface.bufferedLen() != 0 or !readable(file)) return false;
    file.interface.fillMore() catch |err| return err == error.EndOfStream;
    return false;
}

/// Whether reading the file would return at once, with data or its end.
fn readable(file: *Io.File.Reader) bool {
    if (builtin.os.tag == .windows) {
        // A disk file's read returns at once; anything else may wait, and
        // Windows has no poll to ask.
        const stat = file.file.stat(file.io) catch return false;
        return stat.kind == .file;
    }
    var fds = [_]std.posix.pollfd{.{ .fd = file.file.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    // A failed check cannot say the input ended, so more may come.
    _ = std.posix.poll(&fds, 0) catch return false;
    // Only data or a hang-up promises a read that returns at once; a device
    // poll cannot check reports POLLNVAL, and reading it may wait.
    return fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0;
}

/// Discards the rest of an over-long line.
fn skipLine(input: *Io.Reader) error{ReadFailed}!void {
    _ = input.discardDelimiterInclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return,
        error.ReadFailed => return error.ReadFailed,
    };
}

fn writeReported(output: *Io.Writer, status: Status, report: []const u8) Io.Writer.Error!void {
    // The report ends with a newline; the answer line ends after it.
    std.debug.assert(std.mem.endsWith(u8, report, "\n"));
    try std.json.Stringify.value(Reported{ .status = @backingInt(status), .report = .{ .json = report[0 .. report.len - 1] } }, output_options, output);
    try output.writeByte('\n');
}

noinline fn writeFailed(output: *Io.Writer, err: RequestError, path: ?[]const u8) Io.Writer.Error!void {
    @branchHint(.cold);
    try std.json.Stringify.value(Failed{ .@"error" = @errorName(err), .path = path }, output_options, output);
    try output.writeByte('\n');
}

fn expectLine(comptime expected: []const u8, line: []const u8) !void {
    try std.testing.expectEqualStrings(expected ++ "\n", line);
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

test "input lines are answered in order, the worst status wins and the last line is marked" {
    const io = std.testing.io;
    const long: [max_line_bytes + 1]u8 = @splat('x');
    // The first long line and its newline overflow the buffer; the last one,
    // with no newline, fills it exactly and is refused by its length.
    const text = "{\"before\":\"missing-before.png\",\"after\":\"b.png\"}\n" ++ long ++ "\nnot json\n{\"before\":\"a\",\"after\":\"b\",\"scale\":\"0\"}\n" ++ long;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "lines", .data = text });
    const file = try tmp.dir.openFile(io, "lines", .{});
    defer file.close(io);
    var buffer: [max_line_bytes + 1]u8 = undefined;
    var input = file.readerStreaming(io, &buffer);
    var blocks: reuse.LargeBlocks = .{ .io = io, .backing = std.testing.allocator };
    defer blocks.deinit();
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const status = try lines(io, &blocks, &input, &output.writer);
    try std.testing.expectEqual(Status.failed, status);
    try std.testing.expect(blocks.last);
    try expectLine(
        \\{"status":2,"error":"FileNotFound","path":"missing-before.png"}
        \\{"status":2,"error":"LineTooLong"}
        \\{"status":2,"error":"InvalidInput"}
        \\{"status":2,"error":"InvalidScale"}
        \\{"status":2,"error":"LineTooLong"}
    , output.written());
}

test "input is at its end only once the last line is taken" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "lines", .data = "a\nb" });
    const file = try tmp.dir.openFile(io, "lines", .{});
    defer file.close(io);
    var buffer: [16]u8 = undefined;
    var input = file.readerStreaming(io, &buffer);
    try std.testing.expectEqualStrings("a", (try input.interface.takeDelimiter('\n')).?);
    try std.testing.expect(!atEnd(&input));
    try std.testing.expectEqualStrings("b", (try input.interface.takeDelimiter('\n')).?);
    try std.testing.expect(atEnd(&input));
}

test "command line requests are answered in order and the last is marked" {
    var blocks: reuse.LargeBlocks = .{ .io = std.testing.io, .backing = std.testing.allocator };
    defer blocks.deinit();
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const list = [_]Request{
        .{ .paths = .{ .before = "missing-a.png", .after = "b.png" } },
        .{ .paths = .{ .before = "missing-c.png", .after = "d.png" } },
    };
    const status = try requests(std.testing.io, &blocks, &list, &output.writer);
    try std.testing.expectEqual(Status.failed, status);
    try std.testing.expect(blocks.last);
    try expectLine(
        \\{"status":2,"error":"FileNotFound","path":"missing-a.png"}
        \\{"status":2,"error":"FileNotFound","path":"missing-c.png"}
    , output.written());
}

test {
    std.testing.refAllDecls(@This());
}
