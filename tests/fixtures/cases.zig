//! Declares the generated fixture variations and file names.
const std = @import("std");

/// Which image in a comparison pair to use.
pub const Side = enum { before, after };
/// File suffixes for the supported fixture encoders.
pub const Format = enum { png, jpg, webp };
/// Palette selected by the synthetic renderer.
pub const Theme = enum { light, dark };
/// Change applied to the second image.
pub const Change = enum {
    /// A block inserted mid-page, pushing later rows down.
    insert,
    /// A changed input field.
    edit,
    /// No change at all.
    identical,
    /// A banner added above the page in a fixed-height viewport.
    banner_added,
    /// The same banner removed, so the page moves up in the viewport.
    banner_removed,
    /// The viewport scrolls up and exposes a red block at the bottom.
    scroll_up,
    /// Only the right-hand settings column moves.
    column_insert,
    /// An insertion clips the bottom card above a fixed footer.
    footer_insert,
    /// A repeated label below the moving viewport can match the visible tail.
    repeated_tail,
    /// An aligned heading is rasterized with a different edge coverage.
    moved_heading,
};

/// Fixture name, logical dimensions, palette, and change.
pub const Case = struct {
    name: []const u8,
    width: usize,
    height: usize,
    sidebar: usize,
    theme: Theme,
    change: Change = .insert,

    /// Returns one encoded image's path inside the generated directory.
    pub fn file(comptime self: Case, comptime side: Side, comptime format: Format) []const u8 {
        return comptime self.name ++ "/" ++ @tagName(side) ++ "." ++ @tagName(format);
    }

    /// Returns the expected report's path inside the generated directory.
    pub fn expectedFile(comptime self: Case) []const u8 {
        return comptime self.name ++ "/expected.json";
    }

    /// Returns the repository-relative path of one encoded image.
    pub fn path(comptime self: Case, comptime side: Side, comptime format: Format) []const u8 {
        return comptime directory ++ "/" ++ self.file(side, format);
    }

    /// Returns the repository-relative path of the expected report.
    pub fn expected(comptime self: Case) []const u8 {
        return comptime directory ++ "/" ++ self.expectedFile();
    }

    /// Lists every file the generator writes for this case, inside the generated directory.
    pub fn files(comptime self: Case) []const []const u8 {
        return comptime list: {
            var list: []const []const u8 = &.{self.expectedFile()};
            for (std.meta.tags(Side)) |side| {
                for (std.meta.tags(Format)) |format| list = list ++ .{self.file(side, format)};
            }
            break :list list;
        };
    }
};

/// A tiny PNG whose header claims a 16-bit RGBA image too large to decode;
/// its data is that of a one-pixel image.
pub const Claim = struct {
    name: []const u8,
    width: u32,
    height: u32,

    /// Returns the file's path inside the generated directory.
    pub fn file(comptime self: Claim) []const u8 {
        return comptime self.name ++ ".png";
    }

    /// Returns the file's repository-relative path.
    pub fn path(comptime self: Claim) []const u8 {
        return comptime directory ++ "/" ++ self.file();
    }
};

/// Device pixels per logical pixel used in every fixture.
pub const scale = 2;
/// Repository directory for generated data.
pub const directory = "tests/fixtures/images";

/// Page insertions, top banners, and changed and identical controls.
pub const all = [_]Case{
    .{ .name = "phone-light", .width = 390, .height = 640, .sidebar = 48, .theme = .light },
    .{ .name = "phone-dark", .width = 390, .height = 640, .sidebar = 48, .theme = .dark },
    .{ .name = "desktop-light", .width = 1280, .height = 480, .sidebar = 160, .theme = .light },
    .{ .name = "desktop-dark", .width = 1280, .height = 480, .sidebar = 160, .theme = .dark },
    .{ .name = "changed", .width = 390, .height = 320, .sidebar = 48, .theme = .light, .change = .edit },
    .{ .name = "identical", .width = 32, .height = 32, .sidebar = 0, .theme = .light, .change = .identical },
    .{ .name = "banner-added", .width = 390, .height = 320, .sidebar = 48, .theme = .light, .change = .banner_added },
    .{ .name = "banner-removed", .width = 390, .height = 320, .sidebar = 48, .theme = .dark, .change = .banner_removed },
    .{ .name = "scroll-up", .width = 195, .height = 400, .sidebar = 48, .theme = .light, .change = .scroll_up },
    .{ .name = "settings-column", .width = 768, .height = 820, .sidebar = 192, .theme = .light, .change = .column_insert },
    .{ .name = "clipped-card", .width = 390, .height = 400, .sidebar = 48, .theme = .light, .change = .footer_insert },
    .{ .name = "repeated-tail", .width = 390, .height = 400, .sidebar = 48, .theme = .light, .change = .repeated_tail },
    .{ .name = "moved-heading", .width = 768, .height = 820, .sidebar = 192, .theme = .dark, .change = .moved_heading },
};

/// Headers that claim more memory than one decode may hold.
pub const claims = [_]Claim{
    .{ .name = "claims-16-bit-giant", .width = 8192, .height = 16384 },
};

/// Every file the generator writes, inside the generated directory.
pub const files: []const []const u8 = list: {
    var list: []const []const u8 = &.{};
    for (all) |spec| list = list ++ spec.files();
    for (claims) |claim| list = list ++ .{claim.file()};
    break :list list;
};

/// Returns the first case with the given change.
pub fn find(comptime change: Change) Case {
    inline for (all) |spec| if (spec.change == change) return spec;
    @compileError("no fixture case for " ++ @tagName(change));
}

test "every case lists its report and each encoded side" {
    try std.testing.expectEqual(1 + 2 * std.meta.tags(Format).len, comptime all[0].files().len);
    try std.testing.expectEqualStrings(directory ++ "/phone-light/before.png", comptime all[0].path(.before, .png));
    try std.testing.expectEqual(all.len * all[0].files().len + claims.len, files.len);
    try std.testing.expectEqual(Change.edit, comptime find(.edit).change);
}

test {
    std.testing.refAllDecls(@This());
}
