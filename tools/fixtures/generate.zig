//! Draws reproducible synthetic pages and writes their encoded pairs and expected reports.
const std = @import("std");
const uidiff = @import("uidiff");
const png_format = @import("png_format");
const cases = @import("fixture_cases");
const encode = @import("encode.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const report = uidiff.report;

const Pixel = [4]u8;
const Palette = struct { background: u8, chrome: u8, field: u8, ink: u8, highlight: u8 };
/// A rectangle in logical pixels.
const Rect = struct { x: usize, y: usize, width: usize, height: usize };
const Canvas = struct {
    pixels: []Pixel,
    width: usize,
    height: usize,

    fn init(allocator: Allocator, spec: cases.Case) Allocator.Error!Canvas {
        const width = spec.width * cases.scale;
        const height = spec.height * cases.scale;
        return .{ .width = width, .height = height, .pixels = try allocator.alloc(Pixel, width * height) };
    }

    fn rows(self: Canvas, first: usize, end: usize) []Pixel {
        return self.pixels[first * cases.scale * self.width .. end * cases.scale * self.width];
    }

    fn copyColumn(self: Canvas, source: Canvas, left: usize, start: usize, shift: usize) void {
        const x = left * cases.scale;
        const delta = shift * cases.scale;
        for ((start + shift) * cases.scale..self.height) |y| {
            const dest = y * self.width + x;
            const old = (y - delta) * self.width + x;
            @memcpy(self.pixels[dest..][0 .. self.width - x], source.pixels[old..][0 .. self.width - x]);
        }
    }

    fn paint(self: Canvas, rect: Rect, tone: u8) void {
        self.paintColor(rect, gray(tone));
    }

    fn paintColor(self: Canvas, rect: Rect, color: Pixel) void {
        const scale = cases.scale;
        const x = rect.x * scale;
        const width = rect.width * scale;
        for (rect.y * scale..(rect.y + rect.height) * scale) |y|
            @memset(self.pixels[y * self.width + x ..][0..width], color);
    }
};

const GenerateError = std.process.Args.ToSliceError || Allocator.Error || encode.EncodeError || uidiff.EncodeError ||
    Io.Dir.CreateDirPathError || Io.Dir.CreateDirPathOpenError || Io.Dir.WriteFileError || error{InvalidArguments};

const seed = 0x7c2a_4f91;
const margin = 16;
const first_row = 64;
const row_step = 48;
const insert_y = first_row + 2 * row_step;
const input_width = 128;
const input_height = 16;
const input_offset = 24;
const banner_height = 40;
const page_icon: Rect = .{ .x = 16, .y = 16, .width = 24, .height = 16 };
const settings_shift = 304; // Keep the JPEG pair on an 8-device-pixel block boundary.
const footer_height = 32;
const repeated_height = 8;
const heading_height = 12;
const scroll_rows = 40 / cases.scale;
const red: Pixel = .{ 224, 0, 0, 255 };
const banner_text: Rect = .{ .x = 16, .y = 12, .width = 96, .height = 8 };
const banner_field: Rect = .{ .x = 16, .y = 24, .width = 64, .height = 4 };
const sixteen_bits = 16;

/// Writes the fixture set into the directory named by the only argument.
pub fn main(init: std.process.Init) GenerateError!void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.InvalidArguments;
    var out = try Io.Dir.cwd().createDirPathOpen(init.io, args[1], .{});
    defer out.close(init.io);
    inline for (cases.all) |spec| try generate(init.io, init.gpa, out, spec);
    inline for (cases.claims) |claim| try writeClaim(init.io, init.gpa, out, claim);
}

fn generate(io: Io, allocator: Allocator, out: Io.Dir, comptime spec: cases.Case) GenerateError!void {
    const old = try Canvas.init(allocator, spec);
    defer allocator.free(old.pixels);
    const new = try Canvas.init(allocator, spec);
    defer allocator.free(new.pixels);

    const palette: Palette = switch (spec.theme) {
        .light => .{ .background = 248, .chrome = 218, .field = 196, .ink = 80, .highlight = 104 },
        .dark => .{ .background = 28, .chrome = 50, .field = 65, .ink = 183, .highlight = 156 },
    };
    const edit: Rect = .{ .x = spec.sidebar + margin, .y = first_row + input_offset, .width = input_width, .height = input_height };
    const settings = spec.change == .column_insert or spec.change == .moved_heading;
    const inserted: Rect = .{
        .x = spec.sidebar + margin,
        .y = insert_y,
        .width = align4(spec.width - spec.sidebar - margin * 2),
        .height = if (settings) settings_shift else row_step,
    };
    if (spec.change == .identical) {
        @memset(old.pixels, gray(255));
    } else {
        drawPage(old, spec, palette);
    }
    if (settings) {
        old.paint(.{ .x = 0, .y = 48, .width = 8, .height = spec.height - 48 }, palette.chrome);
        old.paint(.{ .x = spec.sidebar / 2, .y = 48, .width = 8, .height = spec.height - 48 }, palette.background);
        for (0..12) |i| old.paint(.{ .x = spec.sidebar / 2 + 16, .y = 56 + i * 24, .width = 32, .height = 8 }, palette.field);
    }
    const cutoff = spec.height -| inserted.height;
    const heading_x = spec.sidebar + margin + 304;
    const heading_y = cutoff -| 32;
    if (spec.change == .moved_heading) paintHeading(old, heading_x, heading_y, palette, .before);
    const label: Rect = .{ .x = spec.sidebar + margin, .y = cutoff -| 16, .width = 72, .height = repeated_height };
    if (spec.change == .repeated_tail) {
        old.paint(.{ .x = spec.sidebar, .y = cutoff - 32, .width = spec.width - spec.sidebar, .height = inserted.height + 32 }, palette.background);
        old.paint(.{ .x = label.x + 104, .y = cutoff - 28, .width = 64, .height = 8 }, palette.ink);
        old.paint(label, palette.ink + 1);
        old.paint(.{ .x = label.x + 120, .y = cutoff + 4, .width = 104, .height = 16 }, palette.field);
        old.paint(.{ .x = label.x, .y = cutoff + 24, .width = label.width, .height = label.height }, palette.ink);
    }
    const footer = spec.height - footer_height;
    if (spec.change == .footer_insert) {
        old.paint(.{ .x = 0, .y = footer, .width = spec.width, .height = footer_height }, palette.chrome);
        old.paint(.{ .x = spec.sidebar + margin, .y = footer + 8, .width = 64, .height = 8 }, palette.ink);
        old.paint(.{ .x = spec.sidebar + 88, .y = footer - 24, .width = 80, .height = 16 }, palette.ink);
    }
    const revealed: Rect = .{ .x = spec.sidebar + margin, .y = spec.height - 16, .width = 24, .height = 8 };
    @memcpy(new.pixels, old.pixels);
    switch (spec.change) {
        .identical => {},
        .edit => new.paint(edit, palette.highlight),
        .insert, .repeated_tail => {
            @memcpy(new.rows(insert_y + row_step, spec.height), old.rows(insert_y, spec.height - row_step));
            const backdrop = old.rows(insert_y, insert_y + 1);
            for (insert_y..insert_y + row_step) |y| @memcpy(new.rows(y, y + 1), backdrop);
            new.paint(inserted, palette.highlight);
            new.paint(.{ .x = inserted.x + 16, .y = insert_y + 12, .width = 64, .height = 4 }, palette.ink);
            new.paint(.{ .x = inserted.x + 16, .y = insert_y + 28, .width = 96, .height = 8 }, palette.field);
            if (spec.change == .repeated_tail) {
                var moved_label = label;
                moved_label.y += inserted.height;
                new.paint(moved_label, palette.ink);
            }
        },
        .column_insert, .moved_heading => {
            new.copyColumn(old, spec.sidebar, insert_y, inserted.height);
            new.paint(.{ .x = spec.sidebar, .y = insert_y, .width = spec.width - spec.sidebar, .height = inserted.height }, palette.background);
            new.paint(inserted, palette.highlight);
            // A sub-threshold sidebar tint makes this pair exercise partitioning.
            new.paint(.{ .x = 0, .y = 48, .width = 8, .height = spec.height - 48 }, palette.chrome + 1);
            if (spec.change == .moved_heading) paintHeading(new, heading_x, heading_y + inserted.height, palette, .after);
        },
        .footer_insert => {
            @memcpy(new.rows(insert_y + row_step, footer), old.rows(insert_y, footer - row_step));
            const backdrop = old.rows(insert_y, insert_y + 1);
            for (insert_y..insert_y + row_step) |y| @memcpy(new.rows(y, y + 1), backdrop);
            new.paint(inserted, palette.highlight);
        },
        .scroll_up => {
            @memcpy(new.rows(0, spec.height - scroll_rows), old.rows(scroll_rows, spec.height));
            new.paint(.{ .x = 0, .y = spec.height - scroll_rows, .width = spec.width, .height = scroll_rows }, palette.background);
            new.paint(.{ .x = 0, .y = spec.height - scroll_rows, .width = spec.sidebar, .height = scroll_rows }, palette.chrome);
            new.paintColor(revealed, red);
        },
        .banner_added, .banner_removed => {
            @memcpy(new.rows(banner_height, spec.height), old.rows(0, spec.height - banner_height));
            new.paint(.{ .x = 0, .y = 0, .width = spec.width, .height = banner_height }, palette.highlight);
            new.paint(banner_text, palette.ink);
            new.paint(banner_field, palette.field);
            if (spec.change == .banner_removed) {
                const tail = spec.height - banner_height;
                old.paint(.{ .x = spec.sidebar, .y = tail, .width = spec.width - spec.sidebar, .height = banner_height }, palette.background);
                old.paintColor(revealed, red);
            }
        },
    }
    const before = if (spec.change == .banner_removed) new else old;
    const after = if (spec.change == .banner_removed) old else new;

    try out.createDirPath(io, spec.name);
    inline for (comptime std.meta.tags(cases.Format)) |format| {
        try save(io, allocator, out, spec.file(.before, format), format, before);
        try save(io, allocator, out, spec.file(.after, format), format, after);
    }
    const banner = unite(banner_text, banner_field);
    const regions: []const report.Region = switch (spec.change) {
        .identical => &.{},
        .insert, .column_insert, .footer_insert, .repeated_tail, .moved_heading => &.{.{ .number = 1, .kind = .inserted, .before = null, .after = padded(inserted) }},
        .edit => &.{.{ .number = 1, .kind = .changed, .before = padded(edit), .after = padded(edit) }},
        .banner_added => &.{.{ .number = 1, .kind = .inserted, .before = null, .after = padded(banner) }},
        .banner_removed => &.{
            .{ .number = 1, .kind = .removed, .before = padded(banner), .after = null },
            .{ .number = 2, .kind = .inserted, .before = null, .after = padded(revealed) },
        },
        .scroll_up => &.{
            .{ .number = 1, .kind = .removed, .before = padded(.{ .x = page_icon.x, .y = page_icon.y, .width = page_icon.width, .height = scroll_rows - page_icon.y }), .after = null },
            .{ .number = 2, .kind = .inserted, .before = null, .after = padded(revealed) },
        },
    };
    const expected = .{ .version = report.version, .regions = regions, .width = old.width, .height = old.height };
    var output = Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(expected, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    try out.writeFile(io, .{ .sub_path = spec.expectedFile(), .data = output.written() });
}

/// Encodes a one-pixel PNG, then rewrites its header to claim the case's
/// size at 16 bits per channel.
fn writeClaim(io: Io, allocator: Allocator, out: Io.Dir, comptime claim: cases.Claim) GenerateError!void {
    var output = Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    // A nonopaque pixel forces an RGBA header for the forged 16-bit image.
    try uidiff.encodePng(allocator, .{ .width = 1, .height = 1, .pixels = &.{.{ 0, 0, 0, 0 }} }, &output.writer);
    const bytes = output.written();
    png_format.writeDimensions(bytes[png_format.dimensions_offset..][0..png_format.dimensions_bytes], claim.width, claim.height);
    bytes[png_format.profile_offset] = sixteen_bits;
    png_format.rewriteHeaderCrc(bytes[0..png_format.header_end]);
    try out.writeFile(io, .{ .sub_path = claim.file(), .data = bytes });
}

fn drawPage(canvas: Canvas, spec: cases.Case, palette: Palette) void {
    @memset(canvas.pixels, gray(palette.background));
    canvas.paint(.{ .x = 0, .y = 0, .width = spec.width, .height = 48 }, palette.chrome);
    canvas.paint(page_icon, palette.ink);
    canvas.paint(.{ .x = 56, .y = 20, .width = 96, .height = 8 }, palette.ink);
    canvas.paint(.{ .x = 0, .y = 48, .width = spec.sidebar, .height = spec.height - 48 }, palette.chrome);
    for (0..3) |i| {
        canvas.paint(.{ .x = 8, .y = 64 + i * 16, .width = spec.sidebar - 16, .height = 8 }, palette.field);
    }

    var random = std.Random.DefaultPrng.init(seed);
    const x = spec.sidebar + margin;
    const usable = spec.width - x - margin;
    var y: usize = first_row;
    while (y + row_step <= spec.height) : (y += row_step) {
        const text_width = align4(@min(usable, 48 + random.random().uintLessThan(u32, 112)));
        canvas.paint(.{ .x = x, .y = y + 4, .width = text_width, .height = 4 }, palette.ink);
        canvas.paint(.{ .x = x, .y = y + 12, .width = align4(text_width / 2 + 8), .height = 4 }, palette.field);
        canvas.paint(.{ .x = x, .y = y + input_offset, .width = input_width, .height = input_height }, palette.field);
        if (usable >= 240) canvas.paint(.{ .x = x + 160, .y = y + input_offset, .width = 80, .height = input_height }, palette.chrome);
    }
}

fn paintHeading(canvas: Canvas, x: usize, y: usize, palette: Palette, side: cases.Side) void {
    const low: u8 = @intCast((5 * @as(u16, palette.ink) + 3 * @as(u16, palette.background)) / 8);
    const high: u8 = @intCast((3 * @as(u16, palette.ink) + 5 * @as(u16, palette.background)) / 8);
    const left = if (side == .before) low else high;
    const right = if (side == .before) high else low;
    for (0..5) |glyph| {
        const start = x + glyph * 5;
        canvas.paint(.{ .x = start, .y = y, .width = 1, .height = heading_height }, left);
        canvas.paint(.{ .x = start + 1, .y = y, .width = 1, .height = heading_height }, palette.ink);
        canvas.paint(.{ .x = start + 2, .y = y, .width = 1, .height = heading_height }, right);
    }
}

fn gray(tone: u8) Pixel {
    return .{ tone, tone, tone, 255 };
}

fn align4(n: usize) usize {
    return n / 4 * 4;
}

fn unite(a: Rect, b: Rect) Rect {
    const x = @min(a.x, b.x);
    const y = @min(a.y, b.y);
    return .{ .x = x, .y = y, .width = @max(a.x + a.width, b.x + b.width) - x, .height = @max(a.y + a.height, b.y + b.height) - y };
}

/// Pads a rectangle the way the comparison does. Every drawn change is at
/// least the padding away from the image edges, so no clipping applies.
fn padded(rect: Rect) report.Box {
    const scale = cases.scale;
    const space = uidiff.region_padding;
    return .{
        .x = @floatFromInt((rect.x - space) * scale),
        .y = @floatFromInt((rect.y - space) * scale),
        .width = @floatFromInt((rect.width + 2 * space) * scale),
        .height = @floatFromInt((rect.height + 2 * space) * scale),
    };
}

fn save(io: Io, allocator: Allocator, out: Io.Dir, path: []const u8, format: cases.Format, canvas: Canvas) GenerateError!void {
    var output = Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try encode.write(allocator, format, @intCast(canvas.width), @intCast(canvas.height), std.mem.sliceAsBytes(canvas.pixels), &output.writer);
    try out.writeFile(io, .{ .sub_path = path, .data = output.written() });
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(encode);
}
