const std = @import("std");
const limine = @import("limine");

const Cursor = struct { x: u32 = 0, y: u32 = 0 };
const font = @embedFile("font.psf")[4..]; // ignore header
const font_height = 16;
const font_width = 8;

pub const Terminal = struct {
    framebuffer: *limine.Framebuffer,
    foreground: u32 = 0xFFFFFFFF,
    background: u32 = 0x00000000,
    cursor: Cursor = .{},

    fn putChar(self: @This(), glyph: u8) void {
        const fg = self.foreground;
        const bg = self.background;
        const fb = self.framebuffer;
        const cursor = self.cursor;
        const glyph_size = font_height;
        for (0..font_height) |y| {
            var data = font[@as(usize, glyph) * glyph_size + y ..];
            var mask: u8 = 0x80;
            for (0..font_width) |x| {
                const offset = (cursor.y + y) * fb.pitch + (cursor.x + x) * 4;
                if (data[0] & mask != 0) {
                    @as(*u32, @ptrCast(@alignCast(fb.address + offset))).* = fg;
                } else {
                    @as(*u32, @ptrCast(@alignCast(fb.address + offset))).* = bg;
                }
                mask >>= 1;
                if (mask == 0) {
                    mask = 0x80;
                    data = data[1..];
                }
            }
        }
    }

    fn write(self: *@This(), str: []const u8) error{}!usize {
        for (str) |glyph| {
            switch (glyph) {
                '\n' => {
                    self.cursor.x = 0;
                    self.cursor.y += font_height;
                },
                '\t' => self.cursor.x += font_width * 4,
                else => {
                    self.putChar(glyph);
                    self.cursor.x += font_width;
                },
            }

            if (self.cursor.x + font_width > self.framebuffer.width) {
                self.cursor.x = 0;
                self.cursor.y += font_height;
            }
        }

        return str.len;
    }

    pub const Writer = std.io.Writer(*@This(), error{}, write);

    pub fn writer(self: *@This()) Writer {
        return .{ .context = self };
    }
};
