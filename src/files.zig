//! Compares two image files: reads and decodes both, compares them, and writes
//! the annotated sheet, replacing its file only once the sheet is complete.
const std = @import("std");
const values = @import("value.zig");
const codec = @import("codec.zig");
const diff = @import("diff.zig");
const annotate = @import("annotate.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Configures the comparison and limits each file decode.
pub const Options = struct {
    scale: values.Scale = .one,
    max_decode_bytes: usize = values.max_decode_bytes,

    /// Returns the settings used by the pixel comparison.
    pub fn comparison(self: Options) diff.Options {
        return .{ .scale = self.scale };
    }

    /// Checks the comparison settings before opening the inputs.
    pub fn check(self: Options) error{InvalidScale}!diff.Checked {
        return self.comparison().check();
    }
};

/// The files one comparison reads and writes. Slices borrow the caller's.
pub const Paths = struct {
    before: []const u8,
    after: []const u8,
    /// Where to write the annotated sheet, if requested.
    annotate: ?[]const u8 = null,
};

/// Holds the path of the file a failure concerns, borrowed from Paths.
pub const Diagnostics = struct { path: ?[]const u8 = null };

/// Failures laying out or encoding a streamed comparison sheet.
pub const EncodeSheetError = annotate.RenderError || codec.EncodeError;

/// Failures rendering, encoding or writing the annotated sheet.
pub const WriteError = EncodeSheetError || Io.Dir.CreateFileAtomicError ||
    Io.File.Atomic.ReplaceError || Io.File.Writer.Error || Io.Dir.StatFileError || error{IsDir};

/// File, codec, comparison and sheet failures.
pub const CompareError = codec.ReadError || codec.DecodeError || diff.CompareError || WriteError;

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
pub fn compareFiles(io: Io, allocator: Allocator, paths: Paths, options: Options, diagnostics: *Diagnostics) CompareError!diff.Comparison {
    diagnostics.path = null;
    const checked = try options.check();
    if (paths.annotate) |path| try preflightSheet(io, allocator, paths, path, options.max_decode_bytes, diagnostics);
    var shared: SharedAllocator = .{ .io = io, .backing = allocator };
    var pair = try loadPair(io, &shared, paths, options.max_decode_bytes, diagnostics);
    defer pair.before.deinit();
    defer pair.after.deinit();
    if (paths.annotate) |path| {
        // A file may have changed since its header was checked.
        diagnostics.path = path;
        _ = try annotate.reportSize(pair.before.image.size(), pair.after.image.size());
    }
    diagnostics.path = null;
    const result = try diff.compareChecked(allocator, pair.before.image, pair.after.image, checked);
    errdefer result.deinit(allocator);
    if (paths.annotate) |path| {
        diagnostics.path = path;
        try writeSheet(io, allocator, path, pair.before.image, pair.after.image, result);
        diagnostics.path = null;
    }
    return result;
}

/// Streams a comparison sheet as PNG into a caller-supplied writer.
pub fn encodeComparisonSheet(allocator: Allocator, before: values.Image, after: values.Image, result: diff.Comparison, output: *Io.Writer) EncodeSheetError!void {
    const sheet = try annotate.ReportRows.init(allocator, before, after, result.regions, result.moves);
    defer sheet.deinit(allocator);
    try codec.encodePngRows(allocator, sheet.size(), sheet, output);
}

fn loadPair(io: Io, shared: *SharedAllocator, paths: Paths, cap: usize, diagnostics: *Diagnostics) CompareError!DecodedPair {
    const allocator = shared.backing;
    diagnostics.path = paths.before;
    const first = try codec.FileInput.open(io, paths.before);
    defer first.close(io);
    if (!try first.isStreaming(io)) return decodeInOrder(io, allocator, first, null, paths, cap, diagnostics);
    const second = codec.FileInput.open(io, paths.after) catch return decodeInOrder(io, allocator, first, null, paths, cap, diagnostics);
    defer second.close(io);
    if (!(second.isStreaming(io) catch false))
        return decodeInOrder(io, allocator, first, second, paths, cap, diagnostics);

    const locked = shared.allocator();
    var future = io.concurrent(codec.FileInput.stream, .{ second, io, locked, cap }) catch |err| switch (err) {
        // Some Io providers have no worker. Both open files remain usable.
        error.ConcurrencyUnavailable => return decodeInOrder(io, allocator, first, second, paths, cap, diagnostics),
    };
    const streamed = first.stream(io, locked, cap) catch |err| {
        discardStreaming(future.cancel(io));
        return err;
    };
    if (streamed) |image| {
        var before = image;
        errdefer before.deinit();
        diagnostics.path = paths.after;
        const after = (try future.await(io)) orelse try second.decode(io, allocator, cap);
        return .{ .before = before, .after = after };
    }
    // An unsupported first PNG profile may need full-image scratch. Release
    // the second image before falling back to ordered decoding.
    discardStreaming(future.cancel(io));
    return decodeInOrder(io, allocator, first, second, paths, cap, diagnostics);
}

fn decodeInOrder(io: Io, allocator: Allocator, first: codec.FileInput, second: ?codec.FileInput, paths: Paths, cap: usize, diagnostics: *Diagnostics) CompareError!DecodedPair {
    diagnostics.path = paths.before;
    var before = try first.decode(io, allocator, cap);
    errdefer before.deinit();
    diagnostics.path = paths.after;
    const after = if (second) |input| try input.decode(io, allocator, cap) else try codec.decodeFileCapped(io, allocator, paths.after, cap);
    return .{ .before = before, .after = after };
}

fn discardStreaming(result: (codec.ReadError || codec.DecodeError)!?codec.Decoded) void {
    if (result) |decoded| {
        if (decoded) |image| {
            var unused = image;
            unused.deinit();
        }
    } else |_| {
        // The ordered decode owns diagnostics for this attempt.
    }
}

fn preflightSheet(io: Io, allocator: Allocator, paths: Paths, sheet_path: []const u8, cap: usize, diagnostics: *Diagnostics) CompareError!void {
    diagnostics.path = sheet_path;
    try refuseDirectory(io, sheet_path);
    diagnostics.path = paths.before;
    const before = try codec.probeFile(io, allocator, paths.before, cap);
    diagnostics.path = paths.after;
    const after = try codec.probeFile(io, allocator, paths.after, cap);
    diagnostics.path = sheet_path;
    _ = try annotate.reportSize(before, after);
}

fn writeSheet(io: Io, allocator: Allocator, path: []const u8, before: values.Image, after: values.Image, result: diff.Comparison) WriteError!void {
    var file = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer file.deinit(io);
    const buffer = try allocator.alloc(u8, write_buffer_bytes);
    defer allocator.free(buffer);
    var writer = file.file.writer(io, buffer);
    encodeComparisonSheet(allocator, before, after, result, &writer.interface) catch |err| switch (err) {
        error.WriteFailed => return writer.err orelse err,
        else => |other| return other,
    };
    writer.interface.flush() catch return writer.err orelse error.WriteFailed;
    try file.replace(io);
}

/// A directory cannot be replaced by the sheet, and the atomic replace
/// reports it only as Unexpected, so it is refused by name first.
fn refuseDirectory(io: Io, path: []const u8) WriteError!void {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |other| return other,
    };
    if (stat.kind == .directory) return error.IsDir;
}

test "an invalid scale clears file diagnostics before loading" {
    var diagnostics: Diagnostics = .{ .path = "stale" };
    try std.testing.expectError(error.InvalidScale, compareFiles(std.testing.io, std.testing.allocator, .{ .before = "before", .after = "after" }, .{ .scale = .{ .factor = 0 } }, &diagnostics));
    try std.testing.expectEqual(@as(?[]const u8, null), diagnostics.path);
}

test "overlapped PNG decodes keep before-side error priority" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const before_name = "before.capture";
    const after_name = "after.capture";
    const pixels: [16]values.Pixel = @splat(.{ 100, 120, 80, 160 });
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try codec.encodePng(allocator, .{ .width = 4, .height = 4, .pixels = &pixels }, &output.writer);
    try tmp.dir.writeFile(io, .{ .sub_path = before_name, .data = output.written() });
    try tmp.dir.writeFile(io, .{ .sub_path = after_name, .data = output.written() });
    const before = try tmp.dir.realPathFileAlloc(io, before_name, allocator);
    defer allocator.free(before);
    const after = try tmp.dir.realPathFileAlloc(io, after_name, allocator);
    defer allocator.free(after);
    var diagnostics: Diagnostics = .{};
    const paths: Paths = .{ .before = before, .after = after };
    const same = try compareFiles(io, allocator, paths, .{}, &diagnostics);
    defer same.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), same.regions.len);
    const truncated = output.written()[0..41];
    try tmp.dir.writeFile(io, .{ .sub_path = before_name, .data = truncated });
    try tmp.dir.writeFile(io, .{ .sub_path = after_name, .data = truncated });
    try std.testing.expectError(error.InvalidImage, compareFiles(io, allocator, paths, .{}, &diagnostics));
    try std.testing.expectEqualStrings(before, diagnostics.path.?);
    try tmp.dir.writeFile(io, .{ .sub_path = before_name, .data = output.written() });
    try std.testing.expectError(error.InvalidImage, compareFiles(io, allocator, paths, .{}, &diagnostics));
    try std.testing.expectEqualStrings(after, diagnostics.path.?);
}

test {
    std.testing.refAllDecls(@This());
}
