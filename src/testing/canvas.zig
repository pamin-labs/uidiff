//! Procedural screenshot canvases and painters.
const std = @import("std");
const Allocator = std.mem.Allocator;
const test_allocator = std.testing.allocator;

/// Specializes painters for an RGBA image with width, height and packed pixels.
pub fn Painters(comptime Image: type) type {
    return struct {
        const Pixel = std.meta.Elem(@FieldType(Image, "pixels"));

        /// A procedurally painted image owned by the test allocator.
        pub const Canvas = struct {
            view: Image,
            pixels: []Pixel,

            /// Allocates a blank procedural image.
            pub fn init(width: usize, height: usize) Allocator.Error!Canvas {
                const pixels = try test_allocator.alloc(Pixel, width * height);
                @memset(pixels, white);
                return .{ .view = .{ .width = width, .height = height, .pixels = pixels }, .pixels = pixels };
            }

            /// Releases the pixel buffer.
            pub fn deinit(self: Canvas) void {
                test_allocator.free(self.pixels);
            }

            /// Allocates the default square used by small tests.
            pub fn square() Allocator.Error!Canvas {
                return init(64, 64);
            }

            /// Borrows a writable row of painted pixels.
            pub fn row(self: Canvas, y: usize) []Pixel {
                return self.pixels[y * self.view.width ..][0..self.view.width];
            }

            /// Copies a source interval into this image.
            pub fn copyRows(self: Canvas, dest: usize, from: Canvas, first: usize, end: usize) void {
                const w = self.view.width;
                @memcpy(self.pixels[dest * w ..][0 .. (end - first) * w], from.pixels[first * w .. end * w]);
            }

            /// Copies part of each row into the corresponding destination columns.
            pub fn copyColumns(self: Canvas, from: Canvas, left: usize, right: usize, first: usize, end: usize, dest: usize) void {
                for (first..end, dest..) |old_y, new_y| @memcpy(self.row(new_y)[left..right], from.row(old_y)[left..right]);
            }

            /// Paints repeated lines with distinct procedural strokes.
            pub fn text(self: Canvas, left: usize, right: usize, first: usize, seed: usize, ink: u8) void {
                var y = first;
                var row_seed = seed;
                while (y + 9 <= self.view.height) : ({
                    y += 14;
                    row_seed += 1;
                }) {
                    self.line(left, right, y, row_seed, ink);
                }
            }

            /// Paints one line of procedural text.
            pub fn line(self: Canvas, left: usize, right: usize, y: usize, seed: usize, ink: u8) void {
                var x = left + seed * 5 % 7;
                var glyph: usize = 0;
                while (x + 8 < right) : ({
                    x += 9;
                    glyph += 1;
                }) {
                    if ((seed + glyph) % 6 == 5) continue;
                    const shape = seed * 3 + glyph * 7 + seed / 3;
                    const stem = 1 + shape % 4;
                    for (0..9) |stroke_y| {
                        self.row(y + stroke_y)[x + stem - 1 ..][0..4].* =
                            .{ inkShade(ink, 1), inkShade(ink, 4), inkShade(ink, 4), inkShade(ink, 2) };
                    }
                    self.fill(x, y + shape % 7, 6, 1, inkShade(ink, 4));
                }
            }

            /// Replaces the red channel in a rectangle.
            pub fn red(self: Canvas, x: usize, y: usize, w: usize, h: usize, value: u8) void {
                for (y..y + h) |j| for (self.row(j)[x..][0..w]) |*pixel| {
                    pixel[0] = value;
                };
            }

            /// Paints the default small changed block.
            pub fn block(self: Canvas, x: usize, y: usize) void {
                self.red(x, y, block_size, block_size, 0);
            }

            /// Fills a rectangle with a single RGBA colour.
            pub fn fill(self: Canvas, x: usize, y: usize, w: usize, h: usize, color: Pixel) void {
                for (y..y + h) |j| @memset(self.row(j)[x..][0..w], color);
            }

            /// Allocates a copy with added rows.
            pub fn insert(self: Canvas, y: usize, rows: usize, growth: usize) Allocator.Error!Canvas {
                const after = try init(self.view.width, self.view.height + growth);
                after.copyRows(0, self, 0, y);
                after.copyRows(y + rows, self, y, after.view.height - rows);
                return after;
            }
        };

        /// A blank pair for exchanging adjacent rows with independent source pixels.
        pub const RowExchange = struct {
            before: Canvas,
            after: Canvas,

            /// First of the two row bands.
            pub const upper = 40;
            /// Height and displacement of the exchanged bands.
            pub const pitch = 40;

            /// Allocates both canvases at the same size.
            pub fn init() Allocator.Error!RowExchange {
                const before = try Canvas.init(256, 160);
                errdefer before.deinit();
                return .{ .before = before, .after = try Canvas.init(before.view.width, before.view.height) };
            }

            /// Releases both canvases.
            pub fn deinit(self: RowExchange) void {
                self.before.deinit();
                self.after.deinit();
            }

            /// Copies the two source bands to swapped positions.
            pub fn exchange(self: RowExchange) void {
                self.after.copyRows(upper, self.before, upper + pitch, upper + pitch * 2);
                self.after.copyRows(upper + pitch, self.before, upper, upper + pitch);
            }
        };

        /// Opaque white for blank screenshot fixtures.
        pub const white: Pixel = @splat(255);
        /// Side length of the small block used by comparison fixtures.
        pub const block_size = 2;

        /// Computes a coverage sample over white paper.
        pub fn inkShade(ink: u8, coverage: u16) Pixel {
            const tone: u8 = @intCast(255 - @as(u16, 255 - ink) * coverage / 4);
            return .{ tone, tone, tone, 255 };
        }

        /// Paints an antialiased diagonal at the given horizontal offset.
        pub fn diagonal(shift: usize) Allocator.Error!Canvas {
            const png = try Canvas.square();
            const samples = 8;
            for (0..png.view.height) |y| {
                for (png.row(y), 0..) |*pixel, x| {
                    var covered: usize = 0;
                    for (0..samples) |sy| {
                        for (0..samples) |sx| {
                            // Distance in units of 1/(4*samples).
                            const distance = (int(x) - 8 - int(shift)) * 4 * samples +
                                2 * (2 * int(sx) + 1) - int(y) * 2 * samples - (2 * int(sy) + 1);
                            if (@abs(distance) < 6 * samples) covered += 1;
                        }
                    }
                    const grey: u8 = @intCast((255 * (samples * samples - covered) + samples * samples / 2) / (samples * samples));
                    pixel.* = .{ grey, grey, grey, 255 };
                }
            }
            return png;
        }

        /// Paints distinct repeating bands in the selected column span.
        pub fn paintBands(canvas: Canvas, x: usize, width: usize) void {
            var top: usize = 0;
            while (top + 7 <= canvas.view.height) : (top += 7) {
                const band = top / 7;
                canvas.red(x + ((band * 7) % (width - 6)), top, 6, 5, @intCast(band % 200));
            }
        }

        /// Draws adjacent cards with independent label and value edits. The caller owns both canvases.
        pub fn compactCardEdits() Allocator.Error![2]Canvas {
            const before = try Canvas.init(480, 164);
            errdefer before.deinit();
            const after = try Canvas.init(480, 164);
            for ([_]Canvas{ before, after }) |image| {
                for ([_]usize{ 20, 254 }) |left| {
                    image.fill(left, 20, 198, 112, inkShade(120, 4));
                    image.fill(left + 2, 22, 194, 108, inkShade(240, 4));
                }
            }
            for ([_]usize{ 52, 286 }) |left| {
                before.fill(left, 44, 40, 12, inkShade(64, 4));
                after.fill(left, 44, 56, 12, inkShade(72, 4));
                before.fill(left, 70, 68, 22, inkShade(64, 4));
                after.fill(left, 70, 82, 22, inkShade(72, 4));
            }
            return .{ before, after };
        }

        /// Paints the edge and label of a single card.
        pub fn paintCard(canvas: Canvas, x: usize, y: usize, width: usize, height: usize, seed: usize) void {
            const edge: Pixel = .{ 180, 183, 189, 255 };
            const visible = @min(height, canvas.view.height - y);
            canvas.fill(x, y, width, 1, edge);
            if (visible == height) canvas.fill(x, y + height - 1, width, 1, edge);
            canvas.fill(x, y, 1, visible, edge);
            canvas.fill(x + width - 1, y, 1, visible, edge);
            if (visible >= 17) canvas.line(x + 12, x + 86, y + 8, seed, 40);
        }

        fn int(n: usize) isize {
            return @intCast(n);
        }
    };
}
