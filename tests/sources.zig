//! Lists the repository's source trees and parses their Zig files for the source tests.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Ast = std.zig.Ast;

/// One parsed Zig file, owned until deinit.
pub const Source = struct {
    /// Repository-relative path with forward slashes.
    path: []const u8,
    text: [:0]const u8,
    tree: Ast,

    /// Releases the path, text and syntax tree.
    pub fn deinit(self: *Source, allocator: Allocator) void {
        self.tree.deinit(allocator);
        allocator.free(self.text);
        allocator.free(self.path);
    }
};

/// Failures listing the source trees.
pub const ListError = Io.Dir.OpenError || Io.Dir.SelectiveWalker.Error || Allocator.Error || error{SourceSymlink};

/// Failures reading or parsing a source file.
pub const ParseError = Io.Dir.ReadFileAllocError || Allocator.Error || error{SyntaxError};

/// The directories every source test covers.
pub const roots = [_][]const u8{ "src", "bench", "tests" };

/// Largest source file read.
const max_source_bytes = 1024 * 1024;

/// Lists every file under the roots as repository-relative paths with
/// forward slashes. The caller frees each path and the list.
pub fn listFiles(io: Io, allocator: Allocator) ListError![][]const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    for (roots) |root| {
        var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .sym_link) return error.SourceSymlink;
            if (entry.kind != .file) continue;
            const path = try std.mem.concat(allocator, u8, &.{ root, "/", entry.path });
            std.mem.replaceScalar(u8, path, '\\', '/');
            errdefer allocator.free(path);
            try paths.append(allocator, path);
        }
    }
    return paths.toOwnedSlice(allocator);
}

/// Frees a list from listFiles.
pub fn freeFiles(allocator: Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

/// Reads and parses one Zig file. Fails on a syntax error.
pub fn parse(io: Io, allocator: Allocator, path: []const u8) ParseError!Source {
    const text = try Io.Dir.cwd().readFileAllocOptions(io, path, allocator, .limited(max_source_bytes), .of(u8), 0);
    errdefer allocator.free(text);
    return fromText(allocator, path, text);
}

/// Parses text the caller allocated; the source then owns it.
pub fn fromText(allocator: Allocator, path: []const u8, text: [:0]const u8) ParseError!Source {
    var tree = try Ast.parse(allocator, text, .{});
    errdefer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.SyntaxError;
    return .{ .path = try allocator.dupe(u8, path), .text = text, .tree = tree };
}

/// Reports whether a path names a Zig file.
pub fn isZig(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zig");
}

test {
    std.testing.refAllDecls(@This());
}
