//! Fails when a binary is larger than its budget. Arguments: path, budget in bytes.
const std = @import("std");
const Io = std.Io;

/// Bad arguments, an unreadable file, or a binary over its budget.
pub const MainError = std.process.Args.ToSliceError || Io.Dir.StatFileError || Io.Writer.Error ||
    error{ InvalidArguments, OverBudget };

/// Checks one binary against its budget and prints both sizes.
pub fn main(init: std.process.Init) MainError!void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.InvalidArguments;
    const budget = std.fmt.parseInt(u64, args[2], 10) catch return error.InvalidArguments;
    const stat = try Io.Dir.cwd().statFile(init.io, args[1], .{});
    var buffer: [256]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &buffer);
    try stdout.interface.print("{s}: {d} bytes, budget {d} bytes\n", .{ std.fs.path.basename(args[1]), stat.size, budget });
    try stdout.interface.flush();
    if (stat.size > budget) return error.OverBudget;
}

test {
    std.testing.refAllDecls(@This());
}
