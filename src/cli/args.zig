//! Owns the CLI argument syntax.
const std = @import("std");
const uidiff = @import("uidiff");
const Request = @import("request.zig").Request;
const Allocator = std.mem.Allocator;

const Flag = enum {
    scale,
    annotate,
    help,
    version,

    fn spelling(comptime self: Flag) [:0]const u8 {
        return "--" ++ @tagName(self);
    }

    // A plain scan over the names: std.meta.stringToEnum's lookup table
    // measured larger on Linux ReleaseSafe.
    noinline fn fromArgument(arg: []const u8) ?Flag {
        if (!isFlag(arg)) return null;
        for (std.enums.values(Flag), std.meta.fieldNames(Flag)) |flag, name| {
            if (std.mem.eql(u8, name, arg[2..])) return flag;
        }
        return null;
    }
};

/// What the arguments ask for.
pub const Command = union(enum) {
    /// The comparisons named on the command line, in order, at least one.
    /// Slices borrow the arguments.
    compare: []const Request,
    /// No arguments: requests come as JSON lines on standard input; the
    /// entry refuses this with no_paths when standard input is a terminal.
    stdin,
    help,
    version,
};

/// The offending argument and why it could not be used.
pub const Issue = struct {
    /// Empty when the offending argument is empty or the issue names none
    /// (no_paths).
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

/// What a bare command is told when standard input is a terminal, where no
/// request lines are coming.
pub const no_paths: Issue = .{ .argument = "", .reason = .missing_paths };

/// Usage text for help and malformed arguments.
pub const usage = @embedFile("usage.txt");

const max_fuzz_args = 8;
const max_fuzz_arg_bytes = 8;
const fuzz_words = [_][:0]const u8{ Flag.scale.spelling(), Flag.annotate.spelling(), Flag.help.spelling(), "2", "1.5", "0x10", "1_0", "out.png" };

/// Parses process arguments into a command. Every group is checked before
/// any is returned, so a usage issue runs no comparison. The request list
/// lives in arena.
pub fn parse(arena: Allocator, args: []const [:0]const u8) Allocator.Error!ParseResult {
    if (args.len <= 1) return .{ .command = .stdin };
    if (args.len == 2) {
        // A plain comparison of the spellings: going through Flag.fromArgument
        // here measured larger on Linux ReleaseSafe.
        if (std.mem.eql(u8, args[1], Flag.help.spelling())) return .{ .command = .help };
        if (std.mem.eql(u8, args[1], Flag.version.spelling())) return .{ .command = .version };
    }
    // Each group takes at least its two paths.
    const list = try arena.alloc(Request, (args.len - 1) / 2);
    var count: usize = 0;
    var seen: std.EnumSet(Flag) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!isFlag(arg)) {
            const after = if (i + 1 < args.len) args[i + 1] else return invalid(arg, .missing_paths);
            if (isFlag(after)) return refuseFlag(after, .flag_before_paths);
            list[count] = .{ .paths = .{ .before = arg, .after = after } };
            count += 1;
            seen = .empty;
            i += 1;
            continue;
        }
        if (count == 0) return refuseFlag(arg, .flag_before_paths);
        const group = &list[count - 1];
        const flag = Flag.fromArgument(arg) orelse return invalid(arg, .unknown_flag);
        // A standalone flag is never inserted, so it falls through to its refusal.
        if (seen.contains(flag)) return invalid(arg, .repeated_flag);
        switch (flag) {
            .help, .version => return invalid(arg, .standalone_only),
            .scale => {
                i += 1;
                const text = flagValue(args, i) orelse return invalid(arg, .missing_value);
                group.options.compare.scale = uidiff.Scale.parse(text) orelse return invalid(text, .invalid_scale);
            },
            .annotate => {
                i += 1;
                group.paths.sheet = flagValue(args, i) orelse return invalid(arg, .missing_value);
            },
        }
        seen.insert(flag);
    }
    return .{ .command = .{ .compare = list[0..count] } };
}

/// Parses arguments the fuzzer builds; the CLI's one fuzz target calls it.
pub fn fuzzParse(_: void, smith: *std.testing.Smith) !void {
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
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = switch (try parse(arena.allocator(), args[0..count])) {
        .command => |command| switch (command) {
            .compare => |list| list,
            .stdin, .help, .version => return,
        },
        .issue => return,
    };
    try std.testing.expect(list.len != 0);
    try std.testing.expectEqualStrings(args[1], list[0].paths.before);
    try std.testing.expectEqualStrings(args[2], list[0].paths.after);
    for (list) |item| {
        try std.testing.expect(!isFlag(item.paths.before));
        try std.testing.expect(!isFlag(item.paths.after));
        try std.testing.expect(item.options.compare.scale.isValid());
    }
}

fn isFlag(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "--");
}

/// Refuses a flag found where a path belongs: an unknown or standalone flag
/// says so, any other is out of place.
fn refuseFlag(arg: []const u8, misplaced: Issue.Reason) ParseResult {
    const reason: Issue.Reason = switch (Flag.fromArgument(arg) orelse return invalid(arg, .unknown_flag)) {
        .help, .version => .standalone_only,
        .scale, .annotate => misplaced,
    };
    return invalid(arg, reason);
}

/// The value after a valued flag at `index`, or null when it is missing.
fn flagValue(args: []const [:0]const u8, index: usize) ?[:0]const u8 {
    if (index == args.len or args[index].len == 0 or isFlag(args[index])) return null;
    return args[index];
}

fn invalid(arg: []const u8, reason: Issue.Reason) ParseResult {
    return .{ .issue = .{ .argument = arg, .reason = reason } };
}

fn expectIssue(argv: []const [:0]const u8, reason: Issue.Reason, argument: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try parse(arena.allocator(), argv);
    try std.testing.expect(result == .issue);
    try std.testing.expectEqual(reason, result.issue.reason);
    try std.testing.expectEqualStrings(argument, result.issue.argument);
}

test "usage agrees with every flag spelling" {
    const expected = comptime std.fmt.comptimePrint(
        "Usage: uidiff <before> <after> [{s} N] [{s} <out.png>] [<before> <after> ...]\n       uidiff < requests.jsonl\n       uidiff {s}\n       uidiff {s}\n",
        .{ Flag.scale.spelling(), Flag.annotate.spelling(), Flag.help.spelling(), Flag.version.spelling() },
    );
    try std.testing.expectEqualStrings(expected, usage);
}

test "options apply to the group they follow" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try parse(arena.allocator(), &.{ "uidiff", "a1", "b1", "--annotate", "s1.png", "a2", "b2", "--scale", "3", "--annotate", "s2.png", "a3", "b3" });
    const list = result.command.compare;
    try std.testing.expectEqual(@as(usize, 3), list.len);
    const defaults: Request = .{ .paths = .{ .before = "", .after = "" } };
    try std.testing.expectEqualStrings("a1", list[0].paths.before);
    try std.testing.expectEqualStrings("b1", list[0].paths.after);
    try std.testing.expectEqualStrings("s1.png", list[0].paths.sheet.?);
    try std.testing.expectEqual(defaults.options.compare.scale.factor, list[0].options.compare.scale.factor);
    try std.testing.expectEqualStrings("s2.png", list[1].paths.sheet.?);
    try std.testing.expectEqual(@as(f64, 3), list[1].options.compare.scale.factor);
    try std.testing.expectEqualStrings("a3", list[2].paths.before);
    try std.testing.expectEqual(@as(?[]const u8, null), list[2].paths.sheet);
    try std.testing.expectEqual(defaults.options.compare.scale.factor, list[2].options.compare.scale.factor);
    for ([_][]const [:0]const u8{ &.{"uidiff"}, &.{} }) |argv| {
        try std.testing.expect((try parse(arena.allocator(), argv)).command == .stdin);
    }
    try std.testing.expect((try parse(arena.allocator(), &.{ "uidiff", "--help" })).command == .help);
    try std.testing.expect((try parse(arena.allocator(), &.{ "uidiff", "--version" })).command == .version);
}

test "malformed groups are usage issues" {
    try expectIssue(&.{ "uidiff", "a", "b", "--annotate", "x.png", "--annotate", "y.png" }, .repeated_flag, "--annotate");
    try expectIssue(&.{ "uidiff", "a", "b", "--annotate" }, .missing_value, "--annotate");
    try expectIssue(&.{ "uidiff", "a", "b", "--annotate", "--scale" }, .missing_value, "--annotate");
    try expectIssue(&.{ "uidiff", "a" }, .missing_paths, "a");
    try expectIssue(&.{ "uidiff", "a", "b", "c" }, .missing_paths, "c");
    try expectIssue(&.{ "uidiff", "--scale", "2", "a", "b" }, .flag_before_paths, "--scale");
    try expectIssue(&.{ "uidiff", "a", "b", "c", "--scale", "2", "d" }, .flag_before_paths, "--scale");
    try expectIssue(&.{ "uidiff", "a", "--json" }, .unknown_flag, "--json");
    try expectIssue(&.{ "uidiff", "a", "b", "--batch" }, .unknown_flag, "--batch");
    try expectIssue(&.{ "uidiff", "--help", "x" }, .standalone_only, "--help");
    try expectIssue(&.{ "uidiff", "a", "b", "--version" }, .standalone_only, "--version");
}

test "a scale that is not a plain decimal is a usage error" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const valid = try parse(arena.allocator(), &.{ "uidiff", "a", "b", "--scale", "1.5" });
    try std.testing.expectEqual(@as(f64, 1.5), valid.command.compare[0].options.compare.scale.factor);
    const huge: [400:0]u8 = @splat('9');
    for ([_][:0]const u8{ "1e2", "nan", "-1", &huge }) |text| try expectIssue(&.{ "uidiff", "a", "b", "--scale", text }, .invalid_scale, text);
}

test {
    std.testing.refAllDecls(@This());
}
