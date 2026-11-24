//! Owns the CLI argument syntax.
const std = @import("std");
const uidiff = @import("uidiff");

/// What the command prints on standard output.
pub const Output = enum { count, json };

/// Parsed paths and output options. Path slices borrow the arguments.
pub const Command = struct {
    paths: uidiff.Paths,
    options: uidiff.Options = .{},
    output: Output = .count,
};

/// Malformed or repeated command arguments.
pub const ParseError = error{InvalidArguments};

/// Usage text for help and malformed arguments.
pub const usage = @embedFile("usage.txt");

const max_fuzz_args = 8;
const max_fuzz_arg_bytes = 8;
const fuzz_words = [_][:0]const u8{ "--json", "--scale", "--annotate", "2", "1.5", "0x10", "1_0", "out.png" };

/// Reports whether the command is asking for help.
pub fn wantsHelp(args: []const [:0]const u8) bool {
    return args.len == 2 and std.mem.eql(u8, args[1], "--help");
}

/// Parses paths and flags from process arguments.
pub fn parse(args: []const [:0]const u8) ParseError!Command {
    if (args.len < 3) return error.InvalidArguments;
    var parsed: Command = .{ .paths = .{ .before = args[1], .after = args[2] } };
    var scale_given = false;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        if (parsed.output == .count and std.mem.eql(u8, flag, "--json")) {
            parsed.output = .json;
            continue;
        }
        if (i + 1 == args.len) return error.InvalidArguments;
        if (!scale_given and std.mem.eql(u8, flag, "--scale")) {
            i += 1;
            parsed.options.scale = uidiff.Scale.parse(args[i]) orelse return error.InvalidArguments;
            scale_given = true;
        } else if (parsed.paths.annotate == null and std.mem.eql(u8, flag, "--annotate")) {
            i += 1;
            if (args[i].len == 0 or std.mem.startsWith(u8, args[i], "--")) return error.InvalidArguments;
            parsed.paths.annotate = args[i];
        } else return error.InvalidArguments;
    }
    return parsed;
}

fn fuzzParse(_: void, smith: *std.testing.Smith) !void {
    var storage: [max_fuzz_args][max_fuzz_arg_bytes + 1]u8 = undefined;
    var args: [max_fuzz_args][:0]const u8 = undefined;
    const count = smith.valueRangeAtMost(u8, 0, max_fuzz_args);
    for (args[0..count], storage[0..count]) |*arg, *buffer| {
        if (smith.value(bool)) {
            arg.* = fuzz_words[smith.index(fuzz_words.len)];
        } else {
            const len = smith.slice(buffer[0..max_fuzz_arg_bytes]);
            buffer[len] = 0;
            arg.* = buffer[0..len :0];
        }
    }
    const command = parse(args[0..count]) catch |err| switch (err) {
        error.InvalidArguments => return,
    };
    try std.testing.expectEqualStrings(args[1], command.paths.before);
    try std.testing.expectEqualStrings(args[2], command.paths.after);
    try std.testing.expect(std.math.isFinite(command.options.scale.factor) and command.options.scale.factor >= 0);
}

test "argument order preserves scale and rejects repeated flags" {
    const args = try parse(&.{ "uidiff", "before", "after", "--json", "--scale", "2", "--annotate", "sheet.png" });
    try std.testing.expectEqual(@as(f64, 2), args.options.scale.factor);
    try std.testing.expect(args.output == .json);
    try std.testing.expectEqualStrings("sheet.png", args.paths.annotate.?);
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "uidiff", "before", "after", "--json", "--json" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "uidiff", "before", "after", "--annotate", "a.png", "--annotate", "b.png" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "uidiff", "before", "after", "--annotate" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "uidiff", "before", "after", "--annotate", "--json" }));
}

test "a scale that is not a plain decimal is a usage error" {
    try std.testing.expectEqual(@as(f64, 1.5), (try parse(&.{ "uidiff", "a", "b", "--scale", "1.5" })).options.scale.factor);
    const huge: [400:0]u8 = @splat('9');
    for ([_][:0]const u8{ "1e2", "nan", "-1", &huge }) |text| {
        try std.testing.expectError(error.InvalidArguments, parse(&.{ "uidiff", "a", "b", "--scale", text }));
    }
}

test "fuzz command arguments" {
    try std.testing.fuzz({}, fuzzParse, .{});
}

test {
    std.testing.refAllDecls(@This());
}
