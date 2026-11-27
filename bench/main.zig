//! Measures the production decode, comparison, and file pipeline on one pair.
const std = @import("std");
const builtin = @import("builtin");
const uidiff = @import("uidiff");
const Io = std.Io;

/// Bad arguments, or a failure of the measured pipeline or the report.
pub const BenchError = std.process.Args.ToSliceError || uidiff.FileCompareError || uidiff.EncodeError ||
    Io.Writer.Error || Io.Clock.ResolutionError || error{InvalidArguments};

/// Per-round timings of each stage, in milliseconds.
const Stages = struct {
    decode: [rounds]f64 = undefined,
    compare: [rounds]f64 = undefined,
    sheet: [rounds]f64 = undefined,
    /// The annotated sheet's encoded size in bytes.
    sheet_bytes: usize = 0,
};

const Measurement = struct {
    workload: []const u8,
    clock: enum { cpu, wall },
    rounds: usize,
    decode_ms: f64,
    compare_ms: f64,
    sheet_ms: f64,
    sheet_bytes: usize,
    pipeline_ms: f64,
    peak_rss_bytes: ?usize,
};

const rounds = 15;

/// Runs one pair in its own process so measurements have independent peak RSS.
/// Arguments: name, before path, after path and an optional scale.
pub fn main(init: std.process.Init) BenchError!void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4 and args.len != 5) return error.InvalidArguments;
    var options: uidiff.FileCompareOptions = .{};
    if (args.len == 5) options.compare.scale = uidiff.Scale.parse(args[4]) orelse return error.InvalidArguments;
    // The CLI's allocator, so the pipeline figure is the command's own.
    const allocator = std.heap.c_allocator;
    const io = init.io;
    const resolution = Io.Clock.cpu_process.resolution(io) catch |err| switch (err) {
        error.ClockUnavailable => Io.Duration.zero,
        error.Unexpected => return err,
    };
    const clock: Io.Clock = if (resolution.nanoseconds == 0) .awake else .cpu_process;
    var stages: Stages = .{};
    try measureStages(io, clock, allocator, args[2], args[3], options.compare, &stages);
    var pipeline_ms: [rounds]f64 = undefined;
    for (&pipeline_ms) |*total| {
        const start = Io.Clock.Timestamp.now(io, clock);
        var diagnostics: uidiff.Diagnostics = .{};
        const result = try uidiff.compareFiles(io, allocator, .{ .before = args[2], .after = args[3] }, options, &diagnostics);
        defer result.deinit(allocator);
        total.* = elapsed(start, io);
        std.mem.doNotOptimizeAway(result.regions);
    }

    var buffer: [256]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buffer);
    try std.json.Stringify.value(Measurement{
        .workload = args[1],
        .clock = if (clock == .cpu_process) .cpu else .wall,
        .rounds = rounds,
        .decode_ms = median(&stages.decode),
        .compare_ms = median(&stages.compare),
        .sheet_ms = median(&stages.sheet),
        .sheet_bytes = stages.sheet_bytes,
        .pipeline_ms = median(&pipeline_ms),
        .peak_rss_bytes = peakRss(),
    }, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}

fn measureStages(io: Io, clock: Io.Clock, allocator: std.mem.Allocator, before_path: []const u8, after_path: []const u8, options: uidiff.CompareOptions, stages: *Stages) BenchError!void {
    const before_bytes = try uidiff.readFile(io, allocator, before_path);
    defer allocator.free(before_bytes);
    const after_bytes = try uidiff.readFile(io, allocator, after_path);
    defer allocator.free(after_bytes);
    var encoded: Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();

    for (&stages.decode, &stages.compare) |*dec_time, *cmp_time| {
        const start = Io.Clock.Timestamp.now(io, clock);
        var before = try uidiff.decode(allocator, before_bytes);
        defer before.deinit();
        var after = try uidiff.decode(allocator, after_bytes);
        defer after.deinit();
        dec_time.* = elapsed(start, io);
        const compare_start = Io.Clock.Timestamp.now(io, clock);
        const result = try uidiff.compare(allocator, .{ .before = before.image, .after = after.image }, options);
        defer result.deinit(allocator);
        cmp_time.* = elapsed(compare_start, io);
    }

    // Time the serial sheet API in separate rounds so its buffers do not
    // disturb the stages above. Measure CLI concurrency through --annotate.
    var before = try uidiff.decode(allocator, before_bytes);
    defer before.deinit();
    var after = try uidiff.decode(allocator, after_bytes);
    defer after.deinit();
    const result = try uidiff.compare(allocator, .{ .before = before.image, .after = after.image }, options);
    defer result.deinit(allocator);
    for (&stages.sheet) |*sheet_time| {
        encoded.clearRetainingCapacity();
        const sheet_start = Io.Clock.Timestamp.now(io, clock);
        try uidiff.encodeSheet(allocator, .{ .before = before.image, .after = after.image }, result.regions, result.moves, &encoded.writer);
        sheet_time.* = elapsed(sheet_start, io);
        stages.sheet_bytes = encoded.written().len;
    }
}

fn elapsed(start: Io.Clock.Timestamp, io: Io) f64 {
    return @as(f64, @floatFromInt(start.durationTo(.now(io, start.clock)).raw.nanoseconds)) / 1_000_000;
}

fn median(values: *[rounds]f64) f64 {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    return values[rounds / 2];
}

fn peakRss() ?usize {
    switch (builtin.os.tag) {
        .macos, .linux => {
            var usage: std.c.rusage = undefined;
            if (std.c.getrusage(std.c.rusage.SELF, &usage) != 0) return null;
            const count = std.math.cast(usize, usage.maxrss) orelse return null;
            return std.math.mul(usize, count, if (builtin.os.tag == .linux) 1024 else 1) catch null;
        },
        else => return null,
    }
}

test "median sorts all samples before selecting the middle" {
    var values: [rounds]f64 = undefined;
    for (&values, 0..) |*value, i| value.* = @floatFromInt(rounds - 1 - i);
    try std.testing.expectEqual(@as(f64, rounds / 2), median(&values));
}

test {
    std.testing.refAllDecls(@This());
}
