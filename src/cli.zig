//! Command entry point, argument translation, output and process exit status.
const std = @import("std");
const uidiff = @import("uidiff");
const args = @import("cli/args.zig");
const cli_options = @import("cli_options");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Prints the panic message without linking stack-trace formatting.
pub const panic = std.debug.simple_panic;

const Exit = enum(u8) { unchanged = 0, changed = 1, failed = 2 };
const RunError = std.process.Args.ToSliceError || uidiff.FileCompareError || uidiff.report.PixelWriteError ||
    Io.File.Writer.Error;

/// Empty: main maps every failure to exit status 2 and a log line, because an
/// error returned from main would exit with 1, the status for changed images.
pub const MainError = error{};

/// The CLI uses filesystem I/O only.
pub const std_options: std.Options = .{ .networking = false };

/// What the command names when standard output fails.
const stdout_name = "stdout";

const log = std.log.scoped(.uidiff);

/// Runs one comparison and returns its process exit status.
pub fn main(init: std.process.Init.Minimal) MainError!u8 {
    // The decoders' many short-lived blocks go through this allocator. libc
    // is linked for the decoders already, and its malloc reuses freed blocks;
    // tests use std.testing.allocator to check for leaks.
    const allocator = std.heap.c_allocator;
    var threaded: Io.Threaded = .init(allocator, .{ .argv0 = .init(init.args), .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();
    // Retain the argument strings until diagnostics have been written.
    var argument_storage: std.heap.ArenaAllocator = .init(allocator);
    defer argument_storage.deinit();
    var diagnostics: uidiff.Diagnostics = .{};
    const status = run(io, allocator, init.args, argument_storage.allocator(), &diagnostics) catch |err| status: {
        if (diagnostics.path) |path| {
            logPathError(path, @errorName(err));
        } else {
            log.err("{t}", .{err});
        }
        break :status Exit.failed;
    };
    return @backingInt(status);
}

fn run(io: Io, allocator: Allocator, input: std.process.Args, arena: Allocator, diagnostics: *uidiff.Diagnostics) RunError!Exit {
    const argv = try input.toSlice(arena);
    if (args.infoRequest(argv)) |request| {
        diagnostics.path = stdout_name;
        const message = switch (request) {
            .help => args.usage,
            .version => cli_options.version ++ "\n",
        };
        try Io.File.stdout().writeStreamingAll(io, message);
        diagnostics.path = null;
        return .unchanged;
    }
    const command = switch (args.parse(argv)) {
        .command => |command| command,
        .issue => |issue| {
            writeUsageError(io, issue);
            return .failed;
        },
    };
    const result = try uidiff.compareFiles(io, allocator, command.paths, command.options, diagnostics);
    defer result.deinit(allocator);
    diagnostics.path = stdout_name;
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buffer);
    write(&stdout.interface, command.output, result) catch |err| return stdout.err orelse err;
    stdout.interface.flush() catch |err| return stdout.err orelse err;
    diagnostics.path = null;
    return if (result.regions.len == 0) .unchanged else .changed;
}

fn write(output: *Io.Writer, format: args.Output, result: uidiff.Comparison) uidiff.report.PixelWriteError!void {
    switch (format) {
        .json => try uidiff.report.writeWholePixels(output, result.regions, result.canvas(), result.moves),
        .count => {
            const count = result.regions.len;
            try output.print("{d} {s}\n", .{ count, if (count == 1) "region" else "regions" });
        },
    }
}

noinline fn writeUsageError(io: Io, issue: args.Issue) void {
    @branchHint(.cold);
    var stderr = Io.File.stderr().writerStreaming(io, &.{});
    const separator: []const u8 = if (issue.argument.len == 0) "" else ": ";
    var message = [_][]const u8{ "uidiff: ", issue.message(), separator, issue.argument, "\n", args.usage };
    // A failing stderr leaves nowhere to report the failure; the exit status still says 2.
    stderr.interface.writeVecAll(&message) catch {};
}

noinline fn logPathError(argument: []const u8, reason: []const u8) void {
    log.err("{f}: {s}", .{ std.zig.fmtString(argument), reason });
}

test {
    std.testing.refAllDecls(args);
}

test {
    std.testing.refAllDecls(@This());
}
