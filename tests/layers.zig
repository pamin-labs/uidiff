//! Checks the layout named in AGENTS.md, the import direction between layers
//! and which files may reach named modules, all read from AGENTS.md's tables.
const std = @import("std");
const sources = @import("sources.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Source = sources.Source;

/// One row of the layer table: its paths and the layers it may import.
const Layer = struct {
    name: []const u8,
    /// Files, or directories ending in a slash. The first file is the layer's root.
    paths: []const []const u8,
    /// Other layers' names, or named modules.
    imports: []const []const u8,
};

/// One row of the module table: a named module, or `export`, and the files
/// or directories allowed to use it.
const Grant = struct { module: []const u8, importers: []const []const u8 };

/// The facade and private implementation directory of a nested module.
const Submodule = struct { facade: []const u8, directory: []const u8 };

/// The rules AGENTS.md states. Slices borrow its text; free with deinit.
const Rules = struct {
    layers: []Layer,
    grants: []Grant,
    submodules: []Submodule,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *Rules) void {
        self.arena.deinit();
    }

    fn layerOf(self: Rules, path: []const u8) ?*const Layer {
        for (self.layers) |*row| if (covered(row.paths, path)) return row;
        return null;
    }

    fn granted(self: Rules, module: []const u8, path: []const u8) bool {
        for (self.grants) |grant| if (std.mem.eql(u8, grant.module, module)) return covered(grant.importers, path);
        return false;
    }
};

const agents_path = "AGENTS.md";
const layout_heading = "## Layout";
const layers_heading = "## Layers";
const max_agents_bytes = 64 * 1024;
/// The module-table row naming files whose exported functions C code calls back.
const export_row = "export";

const sample_agents =
    \\## Layout
    \\- `src/` and `tests/`
    \\## Layers
    \\| Layer | Paths | May import |
    \\| --- | --- | --- |
    \\| value | `src/value.zig` `src/value/` | |
    \\| diff | `src/diff.zig` `src/diff/` | value |
    \\| codec | `src/codec.zig` `src/codec/` | value |
    \\| annotate | `src/annotate.zig` `src/annotate/` | value |
    \\| api | `src/root.zig` | value, diff, codec, annotate |
    \\| cli | `src/cli.zig` `src/cli/` | `uidiff` |
    \\| tool | `bench/` `tests/` | `uidiff` |
    \\
    \\| Module | Importers |
    \\| --- | --- |
    \\| `stb_c` | `src/codec/stb.zig` |
    \\| `export` | `src/codec/stb.zig` |
    \\| `cases` | `tests/fuzz/` |
    \\
    \\| Submodule root | Implementation directory |
    \\| --- | --- |
    \\| `src/diff/regions.zig` | `src/diff/regions/` |
    \\## Gates
;

/// Returns the backticked paths in a section of AGENTS.md. The caller frees the list.
fn sectionPaths(allocator: Allocator, text: []const u8, heading: []const u8) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer paths.deinit(allocator);
    var pieces = std.mem.splitScalar(u8, try section(text, heading), '`');
    var inside = false;
    while (pieces.next()) |piece| : (inside = !inside) {
        if (inside and std.mem.indexOfScalar(u8, piece, '/') != null) try paths.append(allocator, piece);
    }
    return paths.toOwnedSlice(allocator);
}

fn section(text: []const u8, heading: []const u8) ![]const u8 {
    const start = (std.mem.indexOf(u8, text, heading) orelse return error.MissingSection) + heading.len;
    const end = std.mem.indexOfPos(u8, text, start, "\n## ") orelse text.len;
    return text[start..end];
}

/// Reads the layer and module tables from the Layers section.
fn parseRules(allocator: Allocator, text: []const u8) !Rules {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var layers: std.ArrayList(Layer) = .empty;
    var grants: std.ArrayList(Grant) = .empty;
    var submodules: std.ArrayList(Submodule) = .empty;
    var table: enum { none, layers, modules, submodules } = .none;
    var lines = std.mem.splitScalar(u8, try section(text, layers_heading), '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (!std.mem.startsWith(u8, line, "|")) {
            table = .none;
            continue;
        }
        var cells = std.mem.splitScalar(u8, std.mem.trim(u8, line, "|"), '|');
        const first = std.mem.trim(u8, cells.next() orelse continue, " ");
        if (std.mem.startsWith(u8, first, "---")) continue;
        switch (table) {
            .none => table = if (std.mem.eql(u8, first, "Layer"))
                .layers
            else if (std.mem.eql(u8, first, "Module"))
                .modules
            else if (std.mem.eql(u8, first, "Submodule root"))
                .submodules
            else
                return error.UnknownTable,
            .layers => try layers.append(a, .{
                .name = first,
                .paths = try ticks(a, cells.next() orelse return error.ShortRow),
                .imports = try words(a, cells.next() orelse return error.ShortRow),
            }),
            .submodules => try submodules.append(a, .{
                .facade = std.mem.trim(u8, first, "` "),
                .directory = std.mem.trim(u8, cells.next() orelse return error.ShortRow, "` "),
            }),
            .modules => try grants.append(a, .{
                .module = std.mem.trim(u8, first, "` "),
                .importers = try ticks(a, cells.next() orelse return error.ShortRow),
            }),
        }
    }
    if (layers.items.len == 0 or grants.items.len == 0) return error.MissingTable;
    return .{ .layers = layers.items, .grants = grants.items, .submodules = submodules.items, .arena = arena };
}

/// The backticked items of a cell.
fn ticks(allocator: Allocator, cell: []const u8) ![]const []const u8 {
    var items: std.ArrayList([]const u8) = .empty;
    var pieces = std.mem.splitScalar(u8, cell, '`');
    var inside = false;
    while (pieces.next()) |piece| : (inside = !inside) {
        if (inside) try items.append(allocator, piece);
    }
    return items.items;
}

/// The comma-separated items of a cell, backticks dropped.
fn words(allocator: Allocator, cell: []const u8) ![]const []const u8 {
    var items: std.ArrayList([]const u8) = .empty;
    var pieces = std.mem.splitScalar(u8, cell, ',');
    while (pieces.next()) |piece| {
        const word = std.mem.trim(u8, piece, " `");
        if (word.len != 0) try items.append(allocator, word);
    }
    return items.items;
}

fn covered(named: []const []const u8, path: []const u8) bool {
    for (named) |prefix| {
        if (std.mem.eql(u8, prefix, path)) return true;
        if (sources.inDirectory(path, prefix)) return true;
    }
    return false;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |entry| if (std.mem.eql(u8, entry, item)) return true;
    return false;
}

/// Reports whether path is the layer's root: its first path naming a file.
fn isRoot(row: *const Layer, path: []const u8) bool {
    for (row.paths) |named| if (sources.isZig(named)) return std.mem.eql(u8, named, path);
    return false;
}

fn allowedImport(allocator: Allocator, rules: Rules, from_path: []const u8, target: []const u8) !bool {
    if (std.mem.eql(u8, target, "std") or std.mem.eql(u8, target, "builtin")) return true;
    const from = rules.layerOf(from_path) orelse return error.UnclassifiedSource;
    if (!sources.isZig(target)) return contains(from.imports, target) or rules.granted(target, from_path);
    const resolved = try std.fs.path.resolvePosix(allocator, &.{ std.fs.path.dirnamePosix(from_path) orelse ".", target });
    defer allocator.free(resolved);
    const to = rules.layerOf(resolved) orelse return false;
    // Only the standalone comparison test helper may call back through its facade.
    if (std.mem.eql(u8, from_path, "src/diff/test_support.zig") and std.mem.eql(u8, resolved, "src/diff.zig")) return true;
    for (rules.submodules) |submodule| {
        const inside = sources.inDirectory(from_path, submodule.directory);
        const facade = std.mem.eql(u8, from_path, submodule.facade);
        if (inside and std.mem.eql(u8, resolved, submodule.facade)) return false;
        if (sources.inDirectory(resolved, submodule.directory) and !inside and !facade) return false;
    }
    // A file under a layer never imports that layer's own root.
    if (to == from) return !isRoot(to, resolved);
    return isRoot(to, resolved) and contains(from.imports, to.name);
}

fn checkSource(allocator: Allocator, rules: Rules, source: *const Source) !void {
    const tree = &source.tree;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.builtinCallParams(&buffer, node)) |params| {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            if (std.mem.eql(u8, name, "@import")) {
                if (params.len != 1 or tree.nodeTag(params[0]) != .string_literal) return error.InvalidImport;
                const literal = tree.tokenSlice(tree.nodeMainToken(params[0]));
                const target = try std.zig.string_literal.parseAlloc(allocator, literal);
                defer allocator.free(target);
                if (!try allowedImport(allocator, rules, source.path, target)) return error.ForbiddenImport;
            } else if (std.mem.startsWith(u8, source.path, "src/") and std.mem.eql(u8, name, "@setRuntimeSafety")) {
                if (params.len != 1 or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(params[0])), "true"))
                    return error.RuntimeSafetyOptOut;
            } else if (std.mem.eql(u8, name, "@cImport") or std.mem.eql(u8, name, "@cInclude") or std.mem.eql(u8, name, "@extern")) {
                return error.ForeignDeclaration;
            }
        }
        var proto_buffer: [1]Ast.Node.Index = undefined;
        const linkage = if (tree.fullVarDecl(node)) |decl|
            decl.extern_export_token
        else if (tree.fullFnProto(&proto_buffer, node)) |proto|
            proto.extern_export_inline_token
        else
            null;
        if (linkage) |token| switch (tree.tokenTag(token)) {
            .keyword_extern => return error.ForeignDeclaration,
            .keyword_export => if (!rules.granted(export_row, source.path)) return error.ForeignDeclaration,
            else => {},
        };
    }
}

fn checkWithText(path: []const u8, text: [:0]const u8) !void {
    const allocator = testing.allocator;
    var rules = try parseRules(allocator, sample_agents);
    defer rules.deinit();
    var source = try sources.fromText(allocator, path, try allocator.dupeSentinel(u8, text, 0));
    defer source.deinit(allocator);
    try checkSource(allocator, rules, &source);
}

fn readAgents(allocator: Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, agents_path, allocator, .limited(max_agents_bytes));
}

test "every file sits under a path AGENTS.md names, and every named path exists" {
    const io = testing.io;
    const allocator = testing.allocator;
    const text = try readAgents(allocator);
    defer allocator.free(text);
    const named = try sectionPaths(allocator, text, layout_heading);
    defer allocator.free(named);
    try testing.expect(named.len > 0);
    for (named) |path| {
        std.Io.Dir.cwd().access(io, path, .{}) catch |err| {
            std.debug.print("{s} names {s}: {t}\n", .{ agents_path, path, err });
            return err;
        };
    }
    const files = try sources.listFiles(io, allocator);
    defer sources.freeFiles(allocator, files);
    for (files) |path| if (!covered(named, path)) {
        std.debug.print("{s} is not under a path {s} names\n", .{ path, agents_path });
        return error.UnlistedFile;
    };
}

test "every source imports only its layer and permitted lower layers" {
    const io = testing.io;
    const allocator = testing.allocator;
    const text = try readAgents(allocator);
    defer allocator.free(text);
    var rules = try parseRules(allocator, text);
    defer rules.deinit();
    const files = try sources.listFiles(io, allocator);
    defer sources.freeFiles(allocator, files);
    var seen: usize = 0;
    for (files) |path| {
        if (!sources.isZig(path)) continue;
        var source = try sources.parse(io, allocator, path);
        defer source.deinit(allocator);
        checkSource(allocator, rules, &source) catch |err| {
            std.debug.print("{s}: {t}\n", .{ path, err });
            return err;
        };
        seen += 1;
    }
    try testing.expect(seen > 0);
}

test "the guard rejects reverse imports, submodule imports and foreign bindings" {
    const cases = [_]struct { path: []const u8, text: [:0]const u8 }{
        .{ .path = "src/diff/span.zig", .text = "const groups = @import(\"regions/grouping.zig\");" },
        .{ .path = "src/diff/regions/grouping.zig", .text = "const regions = @import(\"../regions.zig\");" },
        .{ .path = "src/diff/rows.zig", .text = "const cli = @import(\"../cli/main.zig\");" },
        .{ .path = "src/diff/rows.zig", .text = "const diff = @import(\"../diff.zig\");" },
        .{ .path = "src/diff/rows.zig", .text = "const labels = @import(\"../annotate/labels.zig\");" },
        .{ .path = "src/diff/rows.zig", .text = "const codec = @import(\"../codec.zig\");" },
        .{ .path = "src/root.zig", .text = "const rows = @import(\"diff/rows.zig\");" },
        .{ .path = "src/value/image.zig", .text = "const values = @import(\"../value.zig\");" },
        .{ .path = "bench/main.zig", .text = "const codec = @import(\"../src/codec.zig\");" },
        .{ .path = "tests/e2e.zig", .text = "const report = @import(\"../src/report.zig\");" },
        .{ .path = "src/codec/png.zig", .text = "const c = @import(\"stb_c\");" },
        .{ .path = "src/cli/args.zig", .text = "const cli = @import(\"../cli.zig\");" },
        .{ .path = "src/cli/args.zig", .text = "const codec = @import(\"../codec.zig\");" },
        .{ .path = "tests/e2e.zig", .text = "const cases = @import(\"cases\");" },
    };
    for (cases) |case| try testing.expectError(error.ForbiddenImport, checkWithText(case.path, case.text));
    try testing.expectError(error.ForeignDeclaration, checkWithText("src/annotate/labels.zig", "extern \"c\" fn encode() void;"));
    try testing.expectError(error.ForeignDeclaration, checkWithText("src/codec/webp.zig", "extern \"c\" fn decode() void;"));
    try testing.expectError(error.ForeignDeclaration, checkWithText("src/codec.zig", "const c = @cImport(@cInclude(\"image.h\"));"));
    try testing.expectError(error.ForeignDeclaration, checkWithText("src/diff.zig", "export fn hook() void {}"));
    try checkWithText("src/codec/stb.zig", "const c = @import(\"stb_c\");\nexport fn hook() void {}");
    try checkWithText("src/diff/regions.zig", "const groups = @import(\"regions/grouping.zig\");");
    try checkWithText("src/diff/regions/grouping.zig", "const pending = @import(\"candidate.zig\");");
    try checkWithText("src/diff/span.zig", "const regions = @import(\"regions.zig\");");
    try checkWithText("src/diff/rows.zig", "const values = @import(\"../value.zig\");");
    try checkWithText("src/diff.zig", "const rows = @import(\"diff/rows.zig\");");
    try checkWithText("src/root.zig", "const diff = @import(\"diff.zig\");");
    try checkWithText("tests/fuzz/decode.zig", "const cases = @import(\"cases\");");
    try checkWithText("tests/e2e.zig", "const cases = @import(\"fixtures/cases.zig\");");
}

test "layout paths come only from the layout section" {
    const named = try sectionPaths(testing.allocator, "# x\n`a/b`\n## Layout\n- `src/` and `uidiff` and `tests/x.zig`\n## Gates\n- `c/d`\n", layout_heading);
    defer testing.allocator.free(named);
    try testing.expectEqual(@as(usize, 2), named.len);
    try testing.expect(covered(named, "src/a/b.zig") and covered(named, "tests/x.zig") and !covered(named, "tests/y.zig"));
}

test "source safety check rejects literal and computed opt-outs" {
    const path = "src/diff.zig";
    try testing.expectError(error.RuntimeSafetyOptOut, checkWithText(path, "fn f() void { @setRuntimeSafety(false); }"));
    try testing.expectError(error.RuntimeSafetyOptOut, checkWithText(path, "const enabled = false; fn f() void { @setRuntimeSafety(enabled); }"));
    try checkWithText(path, "fn f() void { @setRuntimeSafety(true); } // @setRuntimeSafety(false)");
}

test {
    std.testing.refAllDecls(@This());
}
