//! Compares two image files: reads and decodes both, compares them, and writes
//! the annotated sheet, replacing its file only once the sheet is complete.
const std = @import("std");
const builtin = @import("builtin");
const value = @import("value.zig");
const codec = @import("codec.zig");
const diff = @import("diff.zig");
const annotate = @import("annotate.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Configures the comparison and limits each file decode.
pub const FileCompareOptions = struct {
    /// Settings used by the comparison after decoding the inputs.
    compare: diff.Options = .{},
    /// Per-image decode memory budget in bytes, clamped to uidiff.max_decode_bytes.
    max_decode_bytes: usize = value.max_decode_bytes,
};

/// The files one comparison reads and writes. Slices borrow the caller's.
pub const Paths = struct {
    /// Path to the before image.
    before: []const u8,
    /// Path to the after image.
    after: []const u8,
    /// Where to write the annotated sheet, if requested.
    annotate: ?[]const u8 = null,
};

/// Holds the path of the file a failure concerns, borrowed from Paths.
pub const Diagnostics = struct {
    /// Borrowed input or sheet path associated with a failure, or null.
    path: ?[]const u8 = null,
};

/// Failures laying out or encoding a streamed comparison sheet.
pub const EncodeSheetError = annotate.RenderError || codec.EncodeError;

/// Failures rendering, encoding or writing the annotated sheet.
const WriteError = EncodeSheetError || Io.Dir.CreateFileAtomicError ||
    Io.File.Atomic.ReplaceError || Io.File.Writer.Error || Io.Dir.StatFileError || error{ IsDir, SheetIsInput };

/// File, codec, comparison and sheet failures.
pub const FileCompareError = codec.ReadError || codec.DecodeError || diff.CompareError || WriteError;

const DecodedPair = struct { before: codec.Decoded, after: codec.Decoded };

// Decoder blocks retain their allocator until both images are released.
const SharedAllocator = struct {
    io: Io,
    backing: Allocator,
    mutex: Io.Mutex = .init,

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn allocator(self: *SharedAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn lock(context: *anyopaque) *SharedAllocator {
        // allocator installs self as the vtable context.
        const self: *SharedAllocator = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        return self;
    }

    fn alloc(context: *anyopaque, len: usize, align_: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self = lock(context);
        defer self.mutex.unlock(self.io);
        return self.backing.rawAlloc(len, align_, ra);
    }

    fn resize(context: *anyopaque, block: []u8, align_: std.mem.Alignment, len: usize, ra: usize) bool {
        const self = lock(context);
        defer self.mutex.unlock(self.io);
        return self.backing.rawResize(block, align_, len, ra);
    }

    fn remap(context: *anyopaque, block: []u8, align_: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self = lock(context);
        defer self.mutex.unlock(self.io);
        return self.backing.rawRemap(block, align_, len, ra);
    }

    fn free(context: *anyopaque, block: []u8, align_: std.mem.Alignment, ra: usize) void {
        const self = lock(context);
        defer self.mutex.unlock(self.io);
        self.backing.rawFree(block, align_, ra);
    }
};

const write_buffer_bytes = 64 * 1024;

/// Checks the options, decodes both files, compares them, and writes the
/// sheet when paths.annotate is set. On failure, diagnostics names the file
/// concerned, or null when no file is. The caller owns the comparison.
pub fn compareFiles(io: Io, allocator: Allocator, paths: Paths, options: FileCompareOptions, diagnostics: *Diagnostics) FileCompareError!diff.Comparison {
    diagnostics.path = null;
    const checked = try diff.checkOptions(options.compare);
    if (paths.annotate) |path| try preflightSheet(io, allocator, paths, path, options.max_decode_bytes, diagnostics);
    var shared: SharedAllocator = .{ .io = io, .backing = allocator };
    var decoded = try loadPair(io, &shared, paths, options.max_decode_bytes, diagnostics);
    defer decoded.before.deinit();
    defer decoded.after.deinit();
    const pair: value.Pair = .{ .before = decoded.before.image, .after = decoded.after.image };
    if (paths.annotate) |path| {
        // A file may have changed since its header was checked.
        diagnostics.path = path;
        _ = try annotate.minimumSheetSize(pair.before.size(), pair.after.size());
    }
    diagnostics.path = null;
    const result = try diff.compareChecked(allocator, pair.before, pair.after, checked);
    errdefer result.deinit(allocator);
    if (paths.annotate) |path| {
        diagnostics.path = path;
        try writeSheet(io, allocator, path, pair, result);
        diagnostics.path = null;
    }
    return result;
}

/// Streams a comparison sheet as PNG into a caller-supplied writer,
/// compressing a large sheet's strips concurrently through io as
/// compareFiles does, so both give the same bytes.
pub fn encodeSheet(io: Io, allocator: Allocator, pair: value.Pair, regions: []const value.Region, moves: []const value.Move, output: *Io.Writer) EncodeSheetError!void {
    const sheet = try annotate.SheetRows.init(allocator, pair.before, pair.after, regions, moves);
    defer sheet.deinit(allocator);
    try codec.encodePngRowsWithIo(io, allocator, sheet.size(), sheet, output);
}

fn loadPair(io: Io, shared: *SharedAllocator, paths: Paths, cap: usize, diagnostics: *Diagnostics) FileCompareError!DecodedPair {
    const allocator = shared.backing;
    diagnostics.path = paths.before;
    const first = try codec.FileInput.open(io, paths.before);
    defer first.close(io);
    const second = codec.FileInput.open(io, paths.after) catch
        return decodeInOrder(io, allocator, first, null, paths, cap, diagnostics);
    defer second.close(io);
    // The caller decodes before while one worker decodes after. Keep the
    // shared allocator and both handles alive until the task has completed.
    const locked = shared.allocator();
    var worker = io.concurrent(codec.FileInput.decode, .{ second, io, locked, cap }) catch
        return decodeInOrder(io, allocator, first, second, paths, cap, diagnostics);
    const first_result = first.decode(io, locked, cap);
    const second_result = worker.await(io);
    var before = first_result catch |err| {
        if (second_result) |image| {
            var unused = image;
            unused.deinit();
        } else |_| {}
        return err;
    };
    errdefer before.deinit();
    diagnostics.path = paths.after;
    return .{ .before = before, .after = try second_result };
}

fn decodeInOrder(io: Io, allocator: Allocator, first: codec.FileInput, second: ?codec.FileInput, paths: Paths, cap: usize, diagnostics: *Diagnostics) FileCompareError!DecodedPair {
    diagnostics.path = paths.before;
    var before = try first.decode(io, allocator, cap);
    errdefer before.deinit();
    diagnostics.path = paths.after;
    const after = if (second) |input| try input.decode(io, allocator, cap) else try codec.decodeFile(io, allocator, paths.after, cap);
    return .{ .before = before, .after = after };
}

fn preflightSheet(io: Io, allocator: Allocator, paths: Paths, sheet_path: []const u8, cap: usize, diagnostics: *Diagnostics) FileCompareError!void {
    diagnostics.path = sheet_path;
    try checkSheetDestination(io, .cwd(), paths, sheet_path);
    diagnostics.path = paths.before;
    const before = try codec.probeFile(io, allocator, paths.before, cap);
    diagnostics.path = paths.after;
    const after = try codec.probeFile(io, allocator, paths.after, cap);
    diagnostics.path = sheet_path;
    _ = try annotate.minimumSheetSize(before, after);
}

fn writeSheet(io: Io, allocator: Allocator, path: []const u8, pair: value.Pair, result: diff.Comparison) WriteError!void {
    var file = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer file.deinit(io);
    // The file writer reads only bytes it has buffered.
    const buffer = try value.allocUnfilled(u8, allocator, write_buffer_bytes);
    defer value.freeUnfilled(u8, allocator, buffer);
    var writer = file.file.writer(io, buffer);
    encodeSheet(io, allocator, pair, result.regions, result.moves, &writer.interface) catch |err| switch (err) {
        error.WriteFailed => return writer.err orelse err,
        else => |other| return other,
    };
    writer.interface.flush() catch return writer.err orelse error.WriteFailed;
    try file.replace(io);
}

/// A directory cannot be replaced by the sheet (the atomic replace reports it
/// only as Unexpected), and a sheet path naming an input would replace that
/// capture, so both are refused before anything is read or written. A link to
/// an input is refused too: the user named an input, almost surely by mistake.
fn checkSheetDestination(io: Io, dir: Io.Dir, paths: Paths, path: []const u8) WriteError!void {
    const sheet = dir.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |other| return other,
    };
    if (sheet.kind == .directory) return error.IsDir;
    if (sheet.kind != .file) return;
    for ([_][]const u8{ paths.before, paths.after }) |input_path| {
        // An input that cannot be read cannot be the sheet; loading reports it under its own path.
        const input = dir.statFile(io, input_path, .{}) catch continue;
        if (sameFile(input, sheet)) return error.SheetIsInput;
    }
}

// Every spelling, symlink or hard link of one file shares all four fields.
// std.Io.File.Stat has no volume id; two files on different volumes matching
// on all four, to the nanosecond, only refuse the write, never lose data.
fn sameFile(a: Io.File.Stat, b: Io.File.Stat) bool {
    return a.inode == b.inode and a.size == b.size and
        a.mtime.nanoseconds == b.mtime.nanoseconds and a.ctime.nanoseconds == b.ctime.nanoseconds;
}

test "sheet destination refuses both inputs and their hard links" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths: Paths = .{ .before = "before", .after = "after" };
    try tmp.dir.writeFile(io, .{ .sub_path = paths.before, .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = paths.after, .data = "" });
    for ([_][]const u8{ paths.before, paths.after }) |path| {
        try std.testing.expectError(error.SheetIsInput, checkSheetDestination(io, tmp.dir, paths, path));
    }
    // Zig's Windows I/O backend does not implement hard-link creation yet.
    if (builtin.os.tag != .windows) {
        try tmp.dir.hardLink(paths.after, tmp.dir, "hard-link", io, .{});
        try std.testing.expectError(error.SheetIsInput, checkSheetDestination(io, tmp.dir, paths, "hard-link"));
    }
    try checkSheetDestination(io, tmp.dir, paths, "new-sheet");
}

test "an invalid scale clears file diagnostics before loading" {
    var diagnostics: Diagnostics = .{ .path = "stale" };
    try std.testing.expectError(error.InvalidScale, compareFiles(std.testing.io, std.testing.allocator, .{ .before = "before", .after = "after" }, .{ .compare = .{ .scale = .{ .factor = 0 } } }, &diagnostics));
    try std.testing.expectEqual(@as(?[]const u8, null), diagnostics.path);
}

test "overlapped decodes preserve PNG and JPEG errors and results" {
    const jpeg = @import("testing/jpeg.zig");
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const before_name = "before.capture";
    const after_name = "after.capture";
    const pixels: [16]value.Pixel = @splat(.{ 100, 120, 80, 160 });
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try codec.encodePng(allocator, .{ .width = 4, .height = 4, .pixels = &pixels }, &output.writer);
    try tmp.dir.writeFile(io, .{ .sub_path = before_name, .data = output.written() });
    try tmp.dir.writeFile(io, .{ .sub_path = after_name, .data = output.written() });
    const before = try tmp.dir.realPathFileAlloc(io, before_name, allocator);
    defer allocator.free(before);
    const after = try tmp.dir.realPathFileAlloc(io, after_name, allocator);
    defer allocator.free(after);
    const paths: Paths = .{ .before = before, .after = after };
    const samples = [_][]const u8{ output.written(), &jpeg.gray };
    for (samples) |old| {
        for (samples) |new| {
            var a = try codec.decode(allocator, old, value.max_decode_bytes);
            defer a.deinit();
            var b = try codec.decode(allocator, new, value.max_decode_bytes);
            defer b.deinit();
            const expected = try diff.compare(allocator, a.image, b.image, .{});
            defer expected.deinit(allocator);

            try tmp.dir.writeFile(io, .{ .sub_path = before_name, .data = old });
            try tmp.dir.writeFile(io, .{ .sub_path = after_name, .data = new });
            var diagnostics: Diagnostics = .{};
            const actual = try compareFiles(io, allocator, paths, .{}, &diagnostics);
            defer actual.deinit(allocator);
            try std.testing.expectEqualDeep(expected, actual);
            try std.testing.expectEqual(@as(?[]const u8, null), diagnostics.path);
        }
    }

    var diagnostics: Diagnostics = .{};
    const encoded_jpeg = &jpeg.gray;
    const truncated = encoded_jpeg[0 .. encoded_jpeg.len - jpeg.eoi.len];
    try tmp.dir.writeFile(io, .{ .sub_path = before_name, .data = truncated });
    try tmp.dir.writeFile(io, .{ .sub_path = after_name, .data = "unsupported" });
    try std.testing.expectError(error.InvalidImage, compareFiles(io, allocator, paths, .{}, &diagnostics));
    try std.testing.expectEqualStrings(before, diagnostics.path.?);
    try tmp.dir.writeFile(io, .{ .sub_path = before_name, .data = encoded_jpeg });
    try tmp.dir.writeFile(io, .{ .sub_path = after_name, .data = truncated });
    try std.testing.expectError(error.InvalidImage, compareFiles(io, allocator, paths, .{}, &diagnostics));
    try std.testing.expectEqualStrings(after, diagnostics.path.?);
    try tmp.dir.deleteFile(io, after_name);
    try std.testing.expectError(error.FileNotFound, compareFiles(io, allocator, paths, .{}, &diagnostics));
    try std.testing.expectEqualStrings(after, diagnostics.path.?);
    try tmp.dir.writeFile(io, .{ .sub_path = before_name, .data = truncated });
    try std.testing.expectError(error.InvalidImage, compareFiles(io, allocator, paths, .{}, &diagnostics));
    try std.testing.expectEqualStrings(before, diagnostics.path.?);
}

test {
    std.testing.refAllDecls(@This());
}
