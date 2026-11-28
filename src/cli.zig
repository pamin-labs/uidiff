//! Command entry point, argument translation, output and process exit status.
const std = @import("std");
const uidiff = @import("uidiff");
const args = @import("cli/args.zig");
const pages = @import("cli/pages.zig");
const batch = @import("cli/batch.zig");
const reuse = @import("cli/reuse.zig");
const Status = @import("cli/status.zig").Status;
const cli_options = @import("cli_options");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Prints the panic message without linking stack-trace formatting.
pub const panic = std.debug.simple_panic;

const RunError = std.process.Args.ToSliceError || uidiff.FileCompareError || uidiff.report.PixelWriteError ||
    Io.File.Writer.Error || Io.File.Reader.Error || error{ReadFailed};

/// Empty: main maps every failure to exit status 2 and a log line, because an
/// error returned from main would exit with 1, the status for changed images.
pub const MainError = error{};

/// The CLI uses filesystem I/O only.
pub const std_options: std.Options = .{ .networking = false };

/// What the command names when standard output fails.
const stdout_name = "stdout";
/// What the batch names when standard input fails.
const stdin_name = "stdin";

const log = std.log.scoped(.uidiff);

/// Runs one comparison, or a batch, and returns its process exit status.
pub fn main(init: std.process.Init.Minimal) MainError!u8 {
    // The decoders' many short-lived blocks go through this allocator. libc
    // is linked for the decoders already, and its malloc reuses freed blocks;
    // tests use std.testing.allocator to check for leaks. On Linux, large
    // blocks go on huge pages instead.
    var huge_pages: pages.HugePages = .{ .backing = std.heap.c_allocator };
    const allocator = huge_pages.allocator();
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
        break :status Status.failed;
    };
    return @backingInt(status);
}

fn run(io: Io, allocator: Allocator, input: std.process.Args, arena: Allocator, diagnostics: *uidiff.Diagnostics) RunError!Status {
    const argv = try input.toSlice(arena);
    if (args.standalone(argv)) |request| {
        const message = switch (request) {
            .batch => return runBatch(io, allocator, arena, diagnostics),
            .help => args.usage,
            .version => cli_options.version ++ "\n",
        };
        diagnostics.path = stdout_name;
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
    return Status.of(result);
}

fn runBatch(io: Io, allocator: Allocator, arena: Allocator, diagnostics: *uidiff.Diagnostics) RunError!Status {
    var blocks: reuse.LargeBlocks = .{ .io = io, .backing = allocator };
    defer blocks.deinit();
    const input_buffer = try arena.alloc(u8, batch.max_line_bytes + 1);
    var stdin = Io.File.stdin().readerStreaming(io, input_buffer);
    var output_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &output_buffer);
    return batch.run(io, blocks.allocator(), &stdin.interface, &stdout.interface) catch |err| switch (err) {
        error.ReadFailed => {
            diagnostics.path = stdin_name;
            return stdin.err orelse err;
        },
        error.WriteFailed => {
            diagnostics.path = stdout_name;
            return stdout.err orelse err;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
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

// The fuzzer runs one fuzz test per test binary, so the CLI's argument and
// batch request parsers share this target.
fn fuzzInput(_: void, smith: *std.testing.Smith) !void {
    if (smith.value(bool)) return args.fuzzParse({}, smith);
    return batch.fuzzParseLine({}, smith);
}

test "fuzz command arguments and batch request lines" {
    try std.testing.fuzz({}, fuzzInput, .{});
}

test {
    std.testing.refAllDecls(args);
    std.testing.refAllDecls(pages);
    std.testing.refAllDecls(batch);
    std.testing.refAllDecls(reuse);
    std.testing.refAllDecls(@import("cli/status.zig"));
}

test {
    std.testing.refAllDecls(@This());
}
