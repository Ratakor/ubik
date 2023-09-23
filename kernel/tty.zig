const std = @import("std");
const limine = @import("limine");

pub const Color = enum(u32) {
    black = 0x000000,
    blue = 0x0000FF,
    green = 0x00FF00,
    cyan = 0x00FFFF,
    red = 0xFF0000,
    magenta = 0xFF00FF,
    yellow = 0xFFFF00,
    white = 0xFFFFFF,
    _,
};

const Writer = std.io.Writer(void, error{}, write);
const Cursor = struct { x: u32 = 0, y: u32 = 0 };

const font = @embedFile("font.psf")[4..]; // ignore header
const font_height = 16;
const font_width = 8;

var framebuffer: []volatile u32 = undefined;
var framebuffer_width: u64 = undefined;
var framebuffer_height: u64 = undefined;
var cursor: Cursor = .{};
pub var foreground = Color.white;
pub var background = Color.black;
pub const writer: Writer = .{ .context = {} };

pub fn init(fb: *limine.Framebuffer) void {
    framebuffer = @as([*]u32, @ptrCast(@alignCast(fb.address)))[0 .. (fb.pitch * fb.height) / 4];
    framebuffer_width = fb.width;
    framebuffer_height = fb.height;
    clear();
}

pub fn clear() void {
    @memset(framebuffer, 0);
    cursor.x = 0;
    cursor.y = 0;
}

fn writeChar(char: u8) void {
    const glyph_size = font_height;
    for (0..font_height) |y| {
        var glyphs = font[@as(usize, char) * glyph_size + y ..];
        var mask: u8 = 0x80;
        for (0..font_width) |x| {
            const idx = cursor.x + x + (cursor.y + y) * framebuffer_width;
            if (glyphs[0] & mask != 0) {
                framebuffer[idx] = @intFromEnum(foreground);
            } else {
                framebuffer[idx] = @intFromEnum(background);
            }
            mask >>= 1;
            if (mask == 0) {
                mask = 0x80;
                glyphs = glyphs[1..];
            }
        }
    }
}


fn write(_: void, str: []const u8) error{}!usize {
    for (str) |char| {
        switch (char) {
            '\n' => {
                cursor.x = 0;
                cursor.y += font_height;
            },
            '\t' => {
                cursor.x += font_width * 8;
            },
            0x08 => { // backspace
                writeChar(' ');
                cursor.x -= font_width;
            },
            else => {
                writeChar(char);
                cursor.x += font_width;
            },
        }

        if (cursor.x >= framebuffer_width) {
            cursor.x = 0;
            cursor.y += font_height;
        }

        if (cursor.y >= framebuffer_height) {
            cursor.y = 0;
            // TODO: handle scrolling
        }
    }

    return str.len;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    std.fmt.format(writer, fmt, args) catch unreachable;
}
