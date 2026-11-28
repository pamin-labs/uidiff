//! Command entry point, argument translation, output and process exit status.
const std = @import("std");
const uidiff = @import("uidiff");
const args = @import("cli/args.zig");
const pages = @import("cli/pages.zig");
const request = @import("cli/request.zig");
const run = @import("cli/run.zig");
const reuse = @import("cli/reuse.zig");
const Status = @import("cli/status.zig").Status;
const cli_options = @import("cli_options");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Prints the panic message without linking stack-trace formatting.
pub const panic = std.debug.simple_panic;

const StartError = std.process.Args.ToSliceError || Allocator.Error || Io.File.Writer.Error || Io.File.Reader.Error || run.Error;

/// Empty: main maps every failure to exit status 2 and a log line, because an
/// error returned from main would exit with 1, the status for changed images.
pub const MainError = error{};

/// The CLI uses filesystem I/O only.
pub const std_options: std.Options = .{ .networking = false };

/// What the command names when standard output fails.
const stdout_name = "stdout";
/// What the command names when standard input fails.
const stdin_name = "stdin";

const log = std.log.scoped(.uidiff);

/// Runs the requested comparisons and returns the process exit status.
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
    // Holds the arguments and the request list for the whole run.
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var failed_stream: ?[]const u8 = null;
    const status = start(io, allocator, arena.allocator(), init.args, &failed_stream) catch |err| status: {
        if (failed_stream) |name| {
            log.err("{s}: {t}", .{ name, err });
        } else {
            log.err("{t}", .{err});
        }
        break :status Status.failed;
    };
    return @backingInt(status);
}

/// Runs the command; on a failed stream, failed_stream names it.
fn start(io: Io, allocator: Allocator, arena: Allocator, input: std.process.Args, failed_stream: *?[]const u8) StartError!Status {
    const argv = try input.toSlice(arena);
    const command = switch (try args.parse(arena, argv)) {
        .command => |command| command,
        .issue => |issue| {
            writeUsageError(io, issue);
            return .failed;
        },
    };
    var output_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &output_buffer);
    // Given a buffer only when requests come on standard input.
    var stdin = Io.File.stdin().readerStreaming(io, &.{});
    // Keeps freed large blocks for the next request, holding the process near
    // one request's memory; it allocates nothing until a comparison does.
    var blocks: reuse.LargeBlocks = .{ .io = io, .backing = allocator };
    defer blocks.deinit();
    const result = switch (command) {
        .help => writeMessage(&stdout.interface, args.usage),
        .version => writeMessage(&stdout.interface, cli_options.version ++ "\n"),
        // With no later request, a kept block would only add to the peak.
        .compare => |list| run.requests(io, if (list.len == 1) allocator else blocks.allocator(), list, &stdout.interface),
        .stdin => lines: {
            stdin = Io.File.stdin().readerStreaming(io, try arena.alloc(u8, run.max_line_bytes + 1));
            break :lines run.lines(io, blocks.allocator(), &stdin.interface, &stdout.interface);
        },
    };
    return result catch |err| switch (err) {
        error.ReadFailed => {
            failed_stream.* = stdin_name;
            return stdin.err orelse err;
        },
        error.WriteFailed => {
            failed_stream.* = stdout_name;
            return stdout.err orelse err;
        },
    };
}

fn writeMessage(output: *Io.Writer, message: []const u8) Io.Writer.Error!Status {
    try output.writeAll(message);
    try output.flush();
    return .unchanged;
}

noinline fn writeUsageError(io: Io, issue: args.Issue) void {
    @branchHint(.cold);
    var stderr = Io.File.stderr().writerStreaming(io, &.{});
    const separator: []const u8 = if (issue.argument.len == 0) "" else ": ";
    var message = [_][]const u8{ "uidiff: ", issue.message(), separator, issue.argument, "\n", args.usage };
    // A failing stderr leaves nowhere to report the failure; the exit status still says 2.
    stderr.interface.writeVecAll(&message) catch {};
}

// The fuzzer runs one fuzz test per test binary, so the CLI's argument and
// request line parsers share this target.
fn fuzzInput(_: void, smith: *std.testing.Smith) !void {
    if (smith.value(bool)) return args.fuzzParse({}, smith);
    return request.fuzzParseLine({}, smith);
}

test "fuzz command arguments and request lines" {
    try std.testing.fuzz({}, fuzzInput, .{});
}

test {
    std.testing.refAllDecls(args);
    std.testing.refAllDecls(pages);
    std.testing.refAllDecls(request);
    std.testing.refAllDecls(run);
    std.testing.refAllDecls(reuse);
    std.testing.refAllDecls(@import("cli/status.zig"));
}

test {
    std.testing.refAllDecls(@This());
}
