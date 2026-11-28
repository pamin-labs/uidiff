//! One comparison the command asks for, and the JSON request line that
//! names one on standard input.
const std = @import("std");
const uidiff = @import("uidiff");
const Allocator = std.mem.Allocator;

/// The files and options of one comparison. Slices borrow the arguments or
/// the request line.
pub const Request = struct {
    paths: uidiff.Paths,
    options: uidiff.FileCompareOptions = .{},
};

/// One input line's fields. Unknown fields are ignored.
const Line = struct {
    before: []const u8,
    after: []const u8,
    /// The `--scale` grammar; the command line's default when absent.
    scale: ?[]const u8 = null,
    /// Where to write the annotated sheet, if wanted.
    annotate: ?[]const u8 = null,
};

const LineField = std.meta.FieldEnum(Line);

/// Why a line names no request.
pub const ParseError = error{ InvalidInput, InvalidScale, OutOfMemory };

const max_fuzz_line_bytes = 64;

/// Parses a request line. Strings borrow line or live in arena.
pub fn parseLine(arena: Allocator, line: []const u8) ParseError!Request {
    var scanner: std.json.Scanner = .initCompleteInput(arena, line);
    const fields = readLine(arena, &scanner) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidInput,
    };
    var request: Request = .{ .paths = .{ .before = fields.before, .after = fields.after } };
    if (fields.annotate) |path| {
        // The command line refuses an empty --annotate value too.
        if (path.len == 0) return error.InvalidInput;
        request.paths.sheet = path;
    }
    if (fields.scale) |text| request.options.compare.scale = uidiff.Scale.parse(text) orelse return error.InvalidScale;
    return request;
}

/// Parses a request line the fuzzer builds; the CLI's one fuzz target calls it.
pub fn fuzzParseLine(_: void, smith: *std.testing.Smith) !void {
    var storage: [max_fuzz_line_bytes]u8 = undefined;
    const line = storage[0..smith.slice(&storage)];
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const request = parseLine(arena.allocator(), line) catch return;
    try std.testing.expect(request.options.compare.scale.isValid());
}

/// Reads one object of string fields into a Line, skipping unknown
/// fields. Driving the scanner directly keeps std.json's generic parser,
/// and the number parsing it brings for byte arrays, out of the binary.
fn readLine(arena: Allocator, scanner: *std.json.Scanner) !Line {
    var values: std.EnumArray(LineField, ?[]const u8) = .initFill(null);
    var seen: std.EnumSet(LineField) = .empty;
    if (try scanner.next() != .object_begin) return error.InvalidInput;
    while (true) {
        const name = switch (try scanner.nextAlloc(arena, .alloc_if_needed)) {
            .object_end => break,
            .string, .allocated_string => |name| name,
            else => return error.InvalidInput,
        };
        const field = lineField(name) orelse {
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

/// A plain scan over four names, as the argument flags are found.
fn lineField(name: []const u8) ?LineField {
    for (std.enums.values(LineField), std.meta.fieldNames(Line)) |field, field_name| {
        if (std.mem.eql(u8, field_name, name)) return field;
    }
    return null;
}

test "a request line names the files and scale of one comparison" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const full = try parseLine(arena.allocator(),
        \\{"before":"a.png","after":"b\u002epng","scale":"1.5","annotate":"sheet.png","note":[1]}
    );
    try std.testing.expectEqualStrings("a.png", full.paths.before);
    try std.testing.expectEqualStrings("b.png", full.paths.after);
    try std.testing.expectEqualStrings("sheet.png", full.paths.sheet.?);
    try std.testing.expectEqual(@as(f64, 1.5), full.options.compare.scale.factor);
    const plain = try parseLine(arena.allocator(), "{\"before\":\"a\",\"after\":\"b\",\"annotate\":null}\r");
    const defaults: Request = .{ .paths = .{ .before = "a", .after = "b" } };
    try std.testing.expectEqual(defaults.options.compare.scale.factor, plain.options.compare.scale.factor);
    try std.testing.expectEqual(@as(?[]const u8, null), plain.paths.sheet);
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

test {
    std.testing.refAllDecls(@This());
}
