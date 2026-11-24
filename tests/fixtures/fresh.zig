//! Fails when regenerating the fixtures would change the committed files.
const std = @import("std");
const options = @import("fixture_options");
const cases = @import("cases.zig");

const max_fixture_bytes = 4 * 1024 * 1024;

test "committed fixtures match a fresh generation byte for byte" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var generated = try std.Io.Dir.cwd().openDir(io, options.generated, .{});
    defer generated.close(io);
    var committed = try std.Io.Dir.cwd().openDir(io, cases.directory, .{});
    defer committed.close(io);
    inline for (cases.files) |file| {
        const fresh = try generated.readFileAlloc(io, file, allocator, .limited(max_fixture_bytes));
        defer allocator.free(fresh);
        const stored = committed.readFileAlloc(io, file, allocator, .limited(max_fixture_bytes)) catch |err| {
            std.debug.print("{s}/{s}: {t}; run zig build fixtures\n", .{ cases.directory, file, err });
            return err;
        };
        defer allocator.free(stored);
        if (!std.mem.eql(u8, fresh, stored)) {
            std.debug.print("{s}/{s} is stale; run zig build fixtures\n", .{ cases.directory, file });
            return error.StaleFixture;
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
