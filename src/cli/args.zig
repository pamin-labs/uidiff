//! Owns the CLI argument syntax.
const std = @import("std");
const uidiff = @import("uidiff");

const Flag = enum {
    scale,
    json,
    annotate,
    help,
    version,

    fn spelling(comptime self: Flag) [:0]const u8 {
        return "--" ++ @tagName(self);
    }

    // A plain scan over five names: std.meta.stringToEnum's lookup table
    // measured about 3 KB larger on Linux ReleaseSafe.
    noinline fn fromArgument(arg: []const u8) ?Flag {
        if (!std.mem.startsWith(u8, arg, "--")) return null;
        for (std.enums.values(Flag), std.meta.fieldNames(Flag)) |flag, name| {
            if (std.mem.eql(u8, name, arg[2..])) return flag;
        }
        return null;
    }
};

/// What the command prints on standard output.
pub const Output = enum { count, json };

/// The information requested by a standalone flag.
pub const Info = enum { help, version };

/// Parsed paths and output options. Path slices borrow the arguments.
pub const Command = struct {
    paths: uidiff.Paths,
    options: uidiff.Options = .{},
    output: Output = .count,
};

/// The offending argument and why it could not be used.
pub const Issue = struct {
    /// Empty when no argument is to blame (no paths were given).
    argument: []const u8,
    reason: Reason,

    const Reason = enum(u3) {
        missing_paths,
        flag_before_paths,
        unknown_flag,
        repeated_flag,
        missing_value,
        invalid_scale,
        standalone_only,
    };

    const messages = std.enums.directEnumArray(Reason, []const u8, 0, .{
        .missing_paths = "expected before and after paths",
        .flag_before_paths = "options must follow both paths",
        .unknown_flag = "unknown option",
        .repeated_flag = "option was repeated",
        .missing_value = "option requires a value",
        .invalid_scale = "scale must be a positive decimal",
        .standalone_only = "option must be used on its own",
    });

    pub fn message(self: Issue) []const u8 {
        return messages[@backingInt(self.reason)];
    }
};

/// The parsed command or the first usage issue.
pub const ParseResult = union(enum) { command: Command, issue: Issue };

/// Usage text for help and malformed arguments.
pub const usage = @embedFile("usage.txt");

const max_fuzz_args = 8;
const max_fuzz_arg_bytes = 8;
const fuzz_words = [_][:0]const u8{ Flag.json.spelling(), Flag.scale.spelling(), Flag.annotate.spelling(), "2", "1.5", "0x10", "1_0", "out.png" };

/// Recognises an information request with no other arguments. It compares the
/// two spellings directly: going through `Flag.fromArgument` here measured
/// about 1.2 KB larger on Linux ReleaseSafe.
pub fn infoRequest(args: []const [:0]const u8) ?Info {
    if (args.len != 2) return null;
    if (std.mem.eql(u8, args[1], Flag.help.spelling())) return .help;
    if (std.mem.eql(u8, args[1], Flag.version.spelling())) return .version;
    return null;
}

/// Parses paths and flags from process arguments.
pub fn parse(args: []const [:0]const u8) ParseResult {
    if (args.len == 0) return invalid("", .missing_paths);
    for (args[1..@min(3, args.len)]) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) continue;
        const reason: Issue.Reason = switch (Flag.fromArgument(arg) orelse return invalid(arg, .unknown_flag)) {
            .help, .version => .standalone_only,
            else => .flag_before_paths,
        };
        return invalid(arg, reason);
    }
    if (args.len < 3) return invalid(if (args.len == 2) args[1] else "", .missing_paths);
    var parsed: Command = .{ .paths = .{ .before = args[1], .after = args[2] } };
    var seen: std.EnumSet(Flag) = .empty;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const flag = Flag.fromArgument(arg) orelse return invalid(arg, .unknown_flag);
        if (flag == .help or flag == .version) return invalid(arg, .standalone_only);
        if (seen.contains(flag)) return invalid(arg, .repeated_flag);
        seen.insert(flag);
        if (flag == .json) {
            parsed.output = .json;
            continue;
        }
        i += 1;
        if (i == args.len or args[i].len == 0 or std.mem.startsWith(u8, args[i], "--")) return invalid(arg, .missing_value);
        if (flag == .scale) {
            const scale = parseScale(args[i]) orelse return invalid(args[i], .invalid_scale);
            parsed.options.scale = scale;
        } else parsed.paths.annotate = args[i];
    }
    return .{ .command = parsed };
}

noinline fn parseScale(text: []const u8) ?uidiff.Scale {
    const scale = uidiff.Scale.parse(text) orelse return null;
    return if (scale.isValid()) scale else null;
}

fn invalid(arg: []const u8, reason: Issue.Reason) ParseResult {
    return .{ .issue = .{ .argument = arg, .reason = reason } };
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
    const command = switch (parse(args[0..count])) {
        .command => |command| command,
        .issue => return,
    };
    try std.testing.expectEqualStrings(args[1], command.paths.before);
    try std.testing.expectEqualStrings(args[2], command.paths.after);
    try std.testing.expect(command.options.scale.isValid());
}

test "usage agrees with every flag spelling" {
    const expected = comptime std.fmt.comptimePrint(
        "Usage: uidiff <before> <after> [{s} N] [{s}] [{s} <out.png>]\n       uidiff {s}\n       uidiff {s}\n",
        .{ Flag.scale.spelling(), Flag.json.spelling(), Flag.annotate.spelling(), Flag.help.spelling(), Flag.version.spelling() },
    );
    try std.testing.expectEqualStrings(expected, usage);
}

test "argument order preserves scale and rejects repeated flags" {
    const result = parse(&.{ "uidiff", "before", "after", "--json", "--scale", "2", "--annotate", "sheet.png" });
    try std.testing.expect(result == .command);
    const args = result.command;
    try std.testing.expectEqual(@as(f64, 2), args.options.scale.factor);
    try std.testing.expect(args.output == .json);
    try std.testing.expectEqualStrings("sheet.png", args.paths.annotate.?);
    const repeated = parse(&.{ "uidiff", "before", "after", "--annotate", "a.png", "--annotate", "b.png" });
    try std.testing.expect(repeated == .issue);
    try std.testing.expectEqual(.repeated_flag, repeated.issue.reason);
    try std.testing.expectEqualStrings("--annotate", repeated.issue.argument);
    for ([_][]const [:0]const u8{
        &.{ "uidiff", "before", "after", "--annotate" },
        &.{ "uidiff", "before", "after", "--annotate", "--json" },
    }) |argv| {
        const missing = parse(argv);
        try std.testing.expect(missing == .issue);
        try std.testing.expectEqual(.missing_value, missing.issue.reason);
        try std.testing.expectEqualStrings("--annotate", missing.issue.argument);
    }
    const bare = parse(&.{"uidiff"});
    try std.testing.expect(bare == .issue);
    try std.testing.expectEqual(.missing_paths, bare.issue.reason);
    try std.testing.expectEqualStrings("", bare.issue.argument);
}

test "a scale that is not a plain decimal is a usage error" {
    const valid = parse(&.{ "uidiff", "a", "b", "--scale", "1.5" });
    try std.testing.expect(valid == .command);
    try std.testing.expectEqual(@as(f64, 1.5), valid.command.options.scale.factor);
    const huge: [400:0]u8 = @splat('9');
    for ([_][:0]const u8{ "1e2", "nan", "-1", &huge }) |text| {
        const result = parse(&.{ "uidiff", "a", "b", "--scale", text });
        try std.testing.expect(result == .issue);
        try std.testing.expectEqual(.invalid_scale, result.issue.reason);
        try std.testing.expectEqualStrings(text, result.issue.argument);
    }
}

test "fuzz command arguments" {
    try std.testing.fuzz({}, fuzzParse, .{});
}

test {
    std.testing.refAllDecls(@This());
}
