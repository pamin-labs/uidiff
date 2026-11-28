//! Checks the layout named in AGENTS.md, the import direction between layers
//! and which files may reach named modules, all read from AGENTS.md's tables.
const std = @import("std");
const files = @import("files.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Source = files.Source;

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

/// One row of the tier table: a unit of a layer and its tier.
/// A unit imports only units of a lower tier.
const Unit = struct { tier: u8, paths: []const []const u8 };

/// The rules AGENTS.md states. Slices borrow its text; free with deinit.
const Rules = struct {
    layers: []Layer,
    grants: []Grant,
    submodules: []Submodule,
    units: []Unit,
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

    /// The unit holding a path, or null outside the tiered directories.
    fn unitOf(self: Rules, path: []const u8) !?*const Unit {
        if (!files.inDirectory(path, diff_directory) and !files.inDirectory(path, annotate_directory)) return null;
        for (self.units) |*unit| if (covered(unit.paths, path)) return unit;
        return error.UntieredSource;
    }
};

const agents_path = "AGENTS.md";
const layout_heading = "## Layout";
const layers_heading = "## Layers";
const max_agents_bytes = 64 * 1024;
/// The module-table row naming files whose exported functions C code calls back.
const export_row = "export";
const testing_root = "src/testing.zig";
/// Files in `src/testing/` that belong to `uidiff`, path-imported by its test declarations.
const library_test_files = [_][]const u8{ "src/testing/jpeg.zig", "src/testing/required.zig" };
const diff_directory = "src/diff/";
const annotate_directory = "src/annotate/";

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
    \\| testing | `src/testing.zig` `src/testing/` | uidiff |
    \\| api | `src/root.zig` | value, diff, codec, annotate |
    \\| cli | `src/cli.zig` `src/cli/` | `uidiff` |
    \\| test | `tests/` | `uidiff` |
    \\| tool | `bench/` `tools/` | `uidiff` |
    \\
    \\| Module | Importers |
    \\| --- | --- |
    \\| `stb_c` | `src/codec/png/stb.zig` |
    \\| `export` | `src/codec/png/stb.zig` |
    \\| `cases` | `tests/fuzz/` |
    \\| `uidiff_testing` | `tests/decode.zig` |
    \\| `uidiff_test_canvas` | `src/diff/` `src/testing.zig` `src/testing/expect.zig` |
    \\
    \\| Submodule root | Implementation directory |
    \\| --- | --- |
    \\| `src/diff/regions.zig` | `src/diff/regions/` |
    \\| `src/diff/rows.zig` | `src/diff/rows/` |
    \\| `src/annotate/sheet.zig` | `src/annotate/sheet/` |
    \\| `src/annotate/drawing.zig` | `src/annotate/drawing/` |
    \\| `src/codec/png.zig` | `src/codec/png/` |
    \\
    \\| Tier | Paths | Holds |
    \\| --- | --- | --- |
    \\| 4 | `src/diff/span.zig` | |
    \\| 3 | `src/diff/motion.zig` | |
    \\| 3 | `src/diff/unpaired.zig` | |
    \\| 2 | `src/diff/rows.zig` `src/diff/rows/` | |
    \\| 2 | `src/diff/regions.zig` `src/diff/regions/` | |
    \\| 1 | `src/diff/columns.zig` | |
    \\| 1 | `src/diff/yiq.zig` | |
    \\| 0 | `src/diff/mask.zig` | |
    \\| 0 | `src/diff/pixel.zig` | |
    \\| 3 | `src/annotate/sheet.zig` `src/annotate/sheet/` | |
    \\| 2 | `src/annotate/badges.zig` | |
    \\| 2 | `src/annotate/ribbons.zig` | |
    \\| 1 | `src/annotate/drawing.zig` `src/annotate/drawing/` | |
    \\| 0 | `src/annotate/geometry.zig` | |
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
    var units: std.ArrayList(Unit) = .empty;
    var table: enum { none, layers, modules, submodules, units } = .none;
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
            else if (std.mem.eql(u8, first, "Tier"))
                .units
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
            .units => try units.append(a, .{
                .tier = try std.fmt.parseInt(u8, first, 10),
                .paths = try ticks(a, cells.next() orelse return error.ShortRow),
            }),
            .modules => try grants.append(a, .{
                .module = std.mem.trim(u8, first, "` "),
                .importers = try ticks(a, cells.next() orelse return error.ShortRow),
            }),
        }
    }
    if (layers.items.len == 0 or grants.items.len == 0 or units.items.len == 0) return error.MissingTable;
    return .{ .layers = layers.items, .grants = grants.items, .submodules = submodules.items, .units = units.items, .arena = arena };
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
        if (files.inDirectory(path, prefix)) return true;
    }
    return false;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |entry| if (std.mem.eql(u8, entry, item)) return true;
    return false;
}

/// Reports whether path is the layer's root: its first path naming a file.
fn isRoot(row: *const Layer, path: []const u8) bool {
    for (row.paths) |named| if (files.isZig(named)) return std.mem.eql(u8, named, path);
    return false;
}

fn enclosingDeclaration(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    const token = tree.nodeMainToken(node);
    for (tree.rootDecls()) |decl| {
        if (token >= tree.firstToken(decl) and token <= tree.lastToken(decl)) return decl;
    }
    return null;
}

fn allowedImport(allocator: Allocator, rules: Rules, source: *const Source, node: Ast.Node.Index, target: []const u8) !bool {
    if (std.mem.eql(u8, target, "std") or std.mem.eql(u8, target, "builtin")) return true;
    const from_path = source.path;
    const from = rules.layerOf(from_path) orelse return error.UnclassifiedSource;
    if (!files.isZig(target)) {
        if (std.mem.eql(u8, target, "uidiff_test_canvas") and !std.mem.eql(u8, from.paths[0], testing_root)) {
            const decl = enclosingDeclaration(&source.tree, node) orelse return false;
            if (source.tree.nodeTag(decl) != .test_decl) return false;
        }
        return contains(from.imports, target) or rules.granted(target, from_path);
    }
    const resolved = try std.fs.path.resolvePosix(allocator, &.{ std.fs.path.dirnamePosix(from_path) orelse ".", target });
    defer allocator.free(resolved);
    const to = rules.layerOf(resolved) orelse return false;
    if (std.mem.eql(u8, to.paths[0], testing_root) and from != to) {
        if (!std.mem.startsWith(u8, from_path, "src/") or !contains(&library_test_files, resolved)) return false;
        const tree = &source.tree;
        const decl = enclosingDeclaration(tree, node) orelse return false;
        return tree.nodeTag(decl) == .test_decl;
    }
    if (from == to) if (try rules.unitOf(from_path)) |from_unit| {
        if (try rules.unitOf(resolved)) |to_unit| {
            if (from_unit != to_unit and to_unit.tier >= from_unit.tier) return false;
        }
    };
    for (rules.submodules) |submodule| {
        const inside = files.inDirectory(from_path, submodule.directory);
        const facade = std.mem.eql(u8, from_path, submodule.facade);
        if (inside and std.mem.eql(u8, resolved, submodule.facade)) return false;
        if (files.inDirectory(resolved, submodule.directory) and !inside and !facade) return false;
    }
    // A file under a layer never imports that layer's own root.
    if (to == from) return !isRoot(to, resolved);
    return isRoot(to, resolved) and contains(from.imports, to.name);
}

fn checkSource(allocator: Allocator, rules: Rules, source: *const Source) !void {
    _ = try rules.unitOf(source.path);
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
                if (!try allowedImport(allocator, rules, source, node, target)) return error.ForbiddenImport;
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
    var source = try files.fromText(allocator, path, try allocator.dupeSentinel(u8, text, 0));
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
    const paths = try files.listFiles(io, allocator);
    defer files.freeFiles(allocator, paths);
    for (paths) |path| if (!covered(named, path)) {
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
    const paths = try files.listFiles(io, allocator);
    defer files.freeFiles(allocator, paths);
    var seen: usize = 0;
    for (paths) |path| {
        if (!files.isZig(path)) continue;
        var source = try files.parse(io, allocator, path);
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
        .{ .path = "src/root.zig", .text = "const png = @import(\"codec/png.zig\");" },
        .{ .path = "src/codec/webp.zig", .text = "const codec = @import(\"../codec.zig\");" },
        .{ .path = "src/codec.zig", .text = "const decoder = @import(\"codec/png/decoder.zig\");" },
        .{ .path = "src/codec/png/decoder.zig", .text = "const png = @import(\"../png.zig\");" },
        .{ .path = "src/codec/png.zig", .text = "const c = @import(\"stb_c\");" },
        .{ .path = "src/cli/args.zig", .text = "const cli = @import(\"../cli.zig\");" },
        .{ .path = "src/cli/args.zig", .text = "const codec = @import(\"../codec.zig\");" },
        .{ .path = "tests/e2e.zig", .text = "const cases = @import(\"cases\");" },
    };
    for (cases) |case| try testing.expectError(error.ForbiddenImport, checkWithText(case.path, case.text));
    try testing.expectError(error.ForeignDeclaration, checkWithText("src/annotate/geometry.zig", "extern \"c\" fn encode() void;"));
    try testing.expectError(error.ForeignDeclaration, checkWithText("src/codec/webp.zig", "extern \"c\" fn decode() void;"));
    try testing.expectError(error.ForeignDeclaration, checkWithText("src/codec.zig", "const c = @cImport(@cInclude(\"image.h\"));"));
    try testing.expectError(error.ForeignDeclaration, checkWithText("src/diff.zig", "export fn hook() void {}"));
    try testing.expectError(error.ForbiddenImport, checkWithText("src/annotate/drawing/canvas.zig", "const ribbons = @import(\"../ribbons.zig\");"));
    try testing.expectError(error.ForbiddenImport, checkWithText("src/annotate/geometry.zig", "const drawing = @import(\"drawing.zig\");"));
    try testing.expectError(error.ForbiddenImport, checkWithText("src/annotate/ribbons.zig", "const badges = @import(\"badges.zig\");"));
    try testing.expectError(error.ForbiddenImport, checkWithText("src/annotate/sheet/plan.zig", "const canvas = @import(\"../drawing/canvas.zig\");"));
    try testing.expectError(error.ForbiddenImport, checkWithText("src/annotate/sheet/plan.zig", "const sheet = @import(\"../sheet.zig\");"));
    try testing.expectError(error.UntieredSource, checkWithText("src/annotate/unlisted.zig", ""));
    try checkWithText("src/annotate/ribbons.zig", "const drawing = @import(\"drawing.zig\");");
    try checkWithText("src/annotate/sheet/plan.zig", "const drawing = @import(\"../drawing.zig\");");
    try checkWithText("src/annotate/sheet.zig", "const plan = @import(\"sheet/plan.zig\");");
    try checkWithText("src/codec/png/stb.zig", "const c = @import(\"stb_c\");\nexport fn hook() void {}");
    try checkWithText("src/root.zig", "const codec = @import(\"codec.zig\");");
    try checkWithText("src/codec.zig", "const png = @import(\"codec/png.zig\");");
    try checkWithText("src/codec/png.zig", "const decoder = @import(\"png/decoder.zig\");");
    try checkWithText("src/codec/png/decoder.zig", "const scanlines = @import(\"scanlines.zig\");");
    try checkWithText("src/diff/regions.zig", "const groups = @import(\"regions/grouping.zig\");");
    try checkWithText("src/diff/regions/grouping.zig", "const pending = @import(\"candidate.zig\");");
    try checkWithText("src/diff/span.zig", "const regions = @import(\"regions.zig\");");
    try checkWithText("src/diff/rows.zig", "const values = @import(\"../value.zig\");");
    try checkWithText("src/diff.zig", "const rows = @import(\"diff/rows.zig\");");
    try checkWithText("src/root.zig", "const diff = @import(\"diff.zig\");");
    try checkWithText("tests/fuzz/decode.zig", "const cases = @import(\"cases\");");
    try checkWithText("tests/e2e.zig", "const cases = @import(\"fixtures/cases.zig\");");
}

test "diff units only import lower tiers and fixtures stay in test scope" {
    try testing.expectError(error.ForbiddenImport, checkWithText("src/diff/yiq.zig", "const regions = @import(\"regions.zig\");"));
    try testing.expectError(error.ForbiddenImport, checkWithText("src/diff/regions/moves.zig", "test { _ = @import(\"../span.zig\"); }"));
    try testing.expectError(error.ForbiddenImport, checkWithText("src/codec.zig", "const sample = @import(\"testing/jpeg.zig\");"));
    try checkWithText("src/codec.zig", "test { _ = @import(\"testing/jpeg.zig\"); }");
    try testing.expectError(error.ForbiddenImport, checkWithText("src/diff/rows/assembly.zig", "test { _ = @import(\"../../testing.zig\"); }"));
    try testing.expectError(error.ForbiddenImport, checkWithText("src/diff/rows/assembly.zig", "test { _ = @import(\"../../testing/canvas.zig\"); }"));
    try testing.expectError(error.ForbiddenImport, checkWithText("src/diff/rows/assembly.zig", "test { _ = @import(\"../../testing/expect.zig\"); }"));
    try testing.expectError(error.ForbiddenImport, checkWithText("src/diff/rows/assembly.zig", "test { _ = @import(\"../../testing/fuzz.zig\"); }"));
    try testing.expectError(error.ForbiddenImport, checkWithText("src/diff/rows/assembly.zig", "const canvas = @import(\"uidiff_test_canvas\");"));
    try checkWithText("src/diff/rows/assembly.zig", "test { _ = @import(\"uidiff_test_canvas\"); }");
    try testing.expectError(error.ForbiddenImport, checkWithText("tests/decode.zig", "const sample = @import(\"../src/testing/jpeg.zig\");"));
    try testing.expectError(error.ForbiddenImport, checkWithText("tests/decode.zig", "test { _ = @import(\"../src/testing/canvas.zig\"); }"));
    try testing.expectError(error.ForbiddenImport, checkWithText("src/testing/expect.zig", "const api = @import(\"../root.zig\");"));
    try testing.expectError(error.ForbiddenImport, checkWithText("bench/main.zig", "const fixtures = @import(\"uidiff_testing\");"));
    try checkWithText("tests/decode.zig", "const fixtures = @import(\"uidiff_testing\");");
    try testing.expectError(error.ForbiddenImport, checkWithText("bench/main.zig", "const sample = @import(\"../src/testing/jpeg.zig\");"));
    try testing.expectError(error.ForbiddenImport, checkWithText("src/codec.zig", "fn f() void { _ = @import(\"testing/jpeg.zig\"); }"));
    try testing.expectError(error.ForbiddenImport, checkWithText("src/diff/rows.zig", "const regions = @import(\"regions.zig\");"));
    try testing.expectError(error.ForbiddenImport, checkWithText("src/diff/regions/logical.zig", "test { _ = @import(\"../rows.zig\"); }"));
    try testing.expectError(error.ForbiddenImport, checkWithText("src/diff/mask.zig", "const pixel = @import(\"pixel.zig\");"));
    try testing.expectError(error.UntieredSource, checkWithText("src/diff/extra.zig", "const pixel = @import(\"pixel.zig\");"));
    try checkWithText("src/diff/yiq.zig", "const mask = @import(\"mask.zig\");");
    try checkWithText("src/diff/rows/band.zig", "const search = @import(\"search.zig\");");
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
