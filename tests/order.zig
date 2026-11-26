//! Checks each Zig file's declaration order: imports, fields, types, constants,
//! init and deinit, public functions, private functions, then tests, with
//! every type declared before another type uses it and file imports named
//! after their basenames.
const std = @import("std");
const sources = @import("sources.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Source = sources.Source;

/// Declaration kinds in the order a container lists them.
const Kind = enum(u8) { import, field, type, constant, lifecycle, public_function, private_function, @"test" };

/// Declaration-order or file-import naming failures.
const OrderError = error{ OutOfOrder, TypeUsedBeforeDeclared, StdNotFirst, ImportNameMismatch, InvalidImportBasename };

/// Also carries failures decoding the import literal.
const CheckError = OrderError || std.zig.string_literal.ParseError;

/// Records the first violation found, for the failure message.
const Finding = struct { line: usize = 0, name: []const u8 = "" };

/// Functions that construct or release a type, listed before its methods.
const lifecycle_names = [_][]const u8{ "init", "deinit" };

fn kindOf(tree: *const Ast, node: Ast.Node.Index) ?Kind {
    switch (tree.nodeTag(node)) {
        .container_field_init, .container_field_align, .container_field => return .field,
        .fn_decl => return functionKind(tree, node),
        .test_decl => return .@"test",
        else => {},
    }
    const decl = tree.fullVarDecl(node) orelse return null;
    const init = decl.ast.init_node.unwrap() orelse return .constant;
    if (isAlias(tree, init)) return .import;
    const name = tree.tokenSlice(decl.ast.mut_token + 1);
    return if (std.ascii.isUpper(name[0])) .type else .constant;
}

fn functionKind(tree: *const Ast, node: Ast.Node.Index) Kind {
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, node).?;
    const name = tree.tokenSlice(proto.name_token.?);
    for (lifecycle_names) |lifecycle| if (std.mem.eql(u8, name, lifecycle)) return .lifecycle;
    // Exported functions are public to the C code that calls them.
    const public = proto.visib_token != null or
        (if (proto.extern_export_inline_token) |token| tree.tokenTag(token) == .keyword_export else false);
    return if (public) .public_function else .private_function;
}

/// An @import or a field chain over one (`std.mem.Allocator`), which names
/// something declared elsewhere.
fn isAlias(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .field_access => isChain(tree, tree.nodeData(node).node_and_token[0]),
        else => isImport(tree, node),
    };
}

fn isChain(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .field_access => isChain(tree, tree.nodeData(node).node_and_token[0]),
        .identifier => true,
        else => isImport(tree, node),
    };
}

fn isImport(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import"),
        else => false,
    };
}

fn importTarget(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    const decl = tree.fullVarDecl(node) orelse return null;
    const init = decl.ast.init_node.unwrap() orelse return null;
    var buffer: [2]Ast.Node.Index = undefined;
    const params = tree.builtinCallParams(&buffer, init) orelse return null;
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(init)), "@import") or params.len != 1 or
        tree.nodeTag(params[0]) != .string_literal) return null;
    return tree.tokenSlice(tree.nodeMainToken(params[0]));
}

fn checkImportNames(allocator: Allocator, tree: *const Ast, finding: *Finding) CheckError!void {
    // Walk the AST so local imports in tests and functions are covered too.
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const literal = importTarget(tree, node) orelse continue;
        const name_token = tree.fullVarDecl(node).?.ast.mut_token + 1;
        const name = tree.tokenSlice(name_token);
        errdefer finding.* = .{ .line = tree.tokenLocation(0, name_token).line + 1, .name = name };
        const path = try std.zig.string_literal.parseAlloc(allocator, literal);
        defer allocator.free(path);
        if (!sources.isZig(path)) continue;
        const basename = std.fs.path.basenamePosix(path);
        const stem = basename[0 .. basename.len - ".zig".len];
        if (!snakeCaseIdentifier(stem)) return error.InvalidImportBasename;
        if (!std.mem.eql(u8, name, stem)) return error.ImportNameMismatch;
    }
}

fn snakeCaseIdentifier(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isLower(name[0])) return false;
    var words = std.mem.splitScalar(u8, name, '_');
    while (words.next()) |word| {
        if (word.len == 0) return false;
        for (word) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn checkContainer(tree: *const Ast, members: []const Ast.Node.Index, finding: *Finding) OrderError!void {
    var last: Kind = .import;
    var first_import = true;
    for (members, 0..) |member, i| {
        const kind = kindOf(tree, member) orelse continue;
        finding.line = tree.tokenLocation(0, tree.firstToken(member)).line + 1;
        if (@backingInt(kind) < @backingInt(last)) return error.OutOfOrder;
        last = kind;
        if (importTarget(tree, member)) |target| {
            if (!first_import and std.mem.eql(u8, target, "\"std\"")) return error.StdNotFirst;
            first_import = false;
        }
        if (kind == .type) try checkLaterTypes(tree, members[i + 1 ..], member, finding);
        try checkNested(tree, member, finding);
    }
}

/// Fails when a type's definition names a type declared later in the same container.
fn checkLaterTypes(tree: *const Ast, later: []const Ast.Node.Index, member: Ast.Node.Index, finding: *Finding) OrderError!void {
    for (later) |other| {
        if (kindOf(tree, other) != .type) continue;
        const decl = tree.fullVarDecl(other).?;
        const name = tree.tokenSlice(decl.ast.mut_token + 1);
        var token = tree.firstToken(member);
        while (token <= tree.lastToken(member)) : (token += 1) {
            if (tree.tokenTag(token) != .identifier or !std.mem.eql(u8, tree.tokenSlice(token), name)) continue;
            // A field access (`x.Name`) names another namespace's declaration.
            if (token > 0 and tree.tokenTag(token - 1) == .period) continue;
            finding.name = name;
            return error.TypeUsedBeforeDeclared;
        }
    }
}

fn checkNested(tree: *const Ast, member: Ast.Node.Index, finding: *Finding) OrderError!void {
    const decl = tree.fullVarDecl(member) orelse return;
    const init = decl.ast.init_node.unwrap() orelse return;
    var buffer: [2]Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buffer, init) orelse return;
    try checkContainer(tree, container.ast.members, finding);
}

fn checkText(text: [:0]const u8) !void {
    const allocator = testing.allocator;
    var source = parsed: {
        const copy = try allocator.dupeSentinel(u8, text, 0);
        errdefer allocator.free(copy);
        break :parsed try sources.fromText(allocator, "case.zig", copy);
    };
    defer source.deinit(allocator);
    var finding: Finding = .{};
    try checkDeclarations(allocator, &source.tree, &finding);
}

fn checkDeclarations(allocator: Allocator, tree: *const Ast, finding: *Finding) CheckError!void {
    try checkImportNames(allocator, tree, finding);
    try checkContainer(tree, tree.rootDecls(), finding);
}

fn checkSource(allocator: Allocator, source: *const Source, comptime check: fn (Allocator, *const Ast, *Finding) CheckError!void) CheckError!void {
    var finding: Finding = .{};
    check(allocator, &source.tree, &finding) catch |err| {
        std.debug.print("{s}:{d}: {t} {s}\n", .{ source.path, finding.line, err, finding.name });
        return err;
    };
}

test "every Zig file declares in order" {
    const io = testing.io;
    const allocator = testing.allocator;
    const files = try sources.listFiles(io, allocator);
    defer sources.freeFiles(allocator, files);
    for (files) |path| {
        if (!sources.isZig(path)) continue;
        var source = try sources.parse(io, allocator, path);
        defer source.deinit(allocator);
        try checkSource(allocator, &source, checkDeclarations);
    }
    var build = try sources.parse(io, allocator, "build.zig");
    defer build.deinit(allocator);
    try checkSource(allocator, &build, checkImportNames);
}

test "the order check rejects each kind of misplacement" {
    try testing.expectError(error.OutOfOrder, checkText("const std = @import(\"std\");\nconst max = 1;\nconst Box = struct {};\n"));
    try testing.expectError(error.OutOfOrder, checkText("const std = @import(\"std\");\nfn f() void {}\nconst Box = struct {};\n"));
    try testing.expectError(error.OutOfOrder, checkText("const std = @import(\"std\");\nconst max = 1;\nconst Alias = std.mem.Allocator;\n"));
    try testing.expectError(error.OutOfOrder, checkText("const std = @import(\"std\");\ntest {}\nfn f() void {}\n"));
    try testing.expectError(error.OutOfOrder, checkText("const std = @import(\"std\");\nfn f() void {}\npub fn g() void {}\n"));
    try testing.expectError(error.OutOfOrder, checkText("const std = @import(\"std\");\nfn f() void {}\nexport fn g() void {}\n"));
    try testing.expectError(error.OutOfOrder, checkText("const S = struct {\n    pub fn get() void {}\n    pub fn init() void {}\n};\n"));
    try testing.expectError(error.OutOfOrder, checkText("const S = struct {\n    fn init() void {}\n    fn square() void {}\n    fn deinit() void {}\n};\n"));
    try testing.expectError(error.OutOfOrder, checkText("const Box = struct {\n    const max = 1;\n    const Inner = struct {};\n};\n"));
    try testing.expectError(error.TypeUsedBeforeDeclared, checkText("const A = struct { b: B };\nconst B = struct {};\n"));
    try testing.expectError(error.StdNotFirst, checkText("const a = @import(\"a.zig\");\nconst std = @import(\"std\");\n"));
    try testing.expectError(error.ImportNameMismatch, checkText("const alias = @import(\"dir/file.zig\");\n"));
    try testing.expectError(error.ImportNameMismatch, checkText("test { const alias = @import(\"dir/file.zig\"); _ = alias; }\n"));
    try testing.expectError(error.ImportNameMismatch, checkText("const alias = @import(\"dir/file\\x2ezig\");\n"));
    try testing.expectError(error.InvalidImportBasename, checkText("const File = @import(\"dir/File.zig\");\n"));
    try checkText("const a = @import(\"a.zig\");\nconst b = @import(\"b.zig\");\n");
    try checkText("const Member = @import(\"dir/file.zig\").Member;\n");
    try checkText("const file = @import(\"dir/\\x66ile.zig\");\n");
    try checkText("const std = @import(\"std\");\nconst a = @import(\"a.zig\");\nconst B = struct {};\nconst A = struct { b: B, c: a.C };\nconst max = 1;\nfn init() void {}\npub fn g() void {}\nexport fn h() void {}\nfn f() void {}\ntest {}\n");
}

test {
    std.testing.refAllDecls(@This());
}
