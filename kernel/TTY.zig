//! Some parts are based on https://github.com/mintsuki/flanterm.git

const std = @import("std");
const term = @import("root").term;

// TODO: termios
// TODO: user_write_lock -> user write on buffer + framebuffer, log user write?

pub const TTY = @This();

cursor_enabled: bool,
scroll_enabled: bool,
control_sequence: bool,
csi: bool,
escape: bool,
osc: bool,
osc_escape: bool,
rrr: bool,
discard_next: bool,
bold: bool,
bg_bold: bool,
reverse_video: bool,
dec_private: bool,
insert_mode: bool,
code_point: u64,
unicode_remaining: usize,
g_select: u8,
charsets: [2]Charset,
current_charset: usize,
escape_offset: usize,
esc_values: std.BoundedArray(u32, 16),
current_fg: ?usize,
current_bg: ?usize,
scroll_top_margin: usize,
scroll_bottom_margin: usize,

rows: usize,
cols: usize,
offset_x: usize,
offset_y: usize,

framebuffer: []volatile u32,
width: usize,
height: usize,

grid: []Char,
queue: std.ArrayListUnmanaged(QueueItem),
map: []?*QueueItem,

text_fg: Color,
text_bg: Color,
cursor_x: usize,
cursor_y: usize,
old_cursor_x: usize,
old_cursor_y: usize,
saved_cursor_x: usize,
saved_cursor_y: usize,

saved_state_text_fg: Color,
saved_state_text_bg: Color,
saved_state_cursor_x: usize,
saved_state_cursor_y: usize,
saved_state_bold: bool,
saved_state_bg_bold: bool,
saved_state_reverse_video: bool,
saved_state_current_charset: usize,
saved_state_current_fg: ?usize,
saved_state_current_bg: ?usize,

// TODO: lock? also don't forget to init it
// read_lock: SpinLock,
// write_lock: SpinLock,

extra_scancodes: bool,
ctrl_active: bool,
shift_active: bool,
capslock_active: bool,

callback: *const CallbackFn,

pub const Reader = std.io.GenericReader(*TTY, error{}, read); // TODO: change to AnyReader?
pub const Writer = std.io.Writer(*TTY, error{}, write);
pub const CallbackFn = fn (*TTY, Callback, u64, u64, u64) void;

pub const Callback = enum(u64) {
    dec = 10,
    bell = 20,
    private_id = 30,
    status_report = 40,
    pos_report = 50,
    kbd_leds = 60,
    mode = 70,
    linux = 80,
};

const Color = enum(u32) {
    black = 0x00000000,
    red = 0x00aa0000,
    green = 0x0000aa00,
    brown = 0x00aa5500,
    blue = 0x000000aa,
    magenta = 0x00aa00aa,
    cyan = 0x0000aaaa,
    grey = 0x00aaaaaa,
    bright_black = 0x00555555,
    bright_red = 0x00ff5555,
    bright_green = 0x0055ff55,
    bright_brown = 0x00ffff55,
    bright_blue = 0x005555ff,
    bright_magenta = 0x00ff55ff,
    bright_cyan = 0x0055ffff,
    bright_grey = 0x00ffffff,
    _,
};

const ScanCode = enum(u8) {
    ctrl = 0x1d,
    ctrl_rel = 0x9d,
    shift_right = 0x36,
    shift_right_rel = 0xb6,
    shift_left = 0x2a,
    shift_left_rel = 0xaa,
    alt_left = 0x38, // TODO, altGr too
    alt_left_rel = 0xb8,
    capslock = 0x3a,
    numlock = 0x45, // TODO

    keypad_enter = 0x1c,
    keypad_slash = 0x35,
    arrow_up = 0x48,
    arrow_left = 0x4b,
    arrow_down = 0x50,
    arrow_right = 0x4d,

    // TODO
    insert = 0x52,
    home = 0x47,
    end = 0x4f,
    pgup = 0x49,
    pgdown = 0x51,
    delete = 0x53,

    _,
};

const Charset = enum {
    default,
    dec_special,
};

const Char = struct {
    c: u32,
    fg: Color,
    bg: Color,
};

const QueueItem = struct {
    x: usize,
    y: usize,
    c: Char,
};

const font_glyphs = 256;
const font_width = 8 + 1; // + 1 for padding
const font_height = 16;
// TODO: add scale/zoom? look for glyph_width/height on commit 984172b

const tab_size = 8;
const default_bg = Color.black;
const default_fg = Color.grey;
const default_bg_bright = Color.bright_black;
const default_fg_bright = Color.bright_grey;

const font = blk: {
    @setEvalBranchQuota(100_000);

    // Builtin font originally taken from:
    // https://github.com/viler-int10h/vga-text-mode-fonts
    const builtin_font = @embedFile("STANDARD.F16");
    const font_bool_size = font_glyphs * font_height * font_width;
    var font_bitmap: [font_bool_size]bool = undefined;

    for (0..font_glyphs) |i| {
        const glyph = builtin_font[i * font_height ..];

        for (0..font_height) |y| {
            // NOTE: the characters in VGA fonts are always one byte wide.
            // 9 dot wide fonts have 8 dots and one empty column, except
            // characters 0xC0-0xDF replicate column 9.
            for (0..8) |x| {
                const idx = i * font_height * font_width + y * font_width + x;
                font_bitmap[idx] = (glyph[y] & (@as(u8, 0x80) >> @intCast(x))) != 0;
            }

            // fill columns above 8 like VGA Line Graphics Mode does
            for (8..font_width) |x| {
                const idx = i * font_height * font_width + y * font_width + x;
                if (i >= 0xc0 and i <= 0xdf) {
                    font_bitmap[idx] = (glyph[y] & 1) != 0;
                } else {
                    font_bitmap[idx] = false;
                }
            }
        }
    }

    break :blk font_bitmap;
};

const ansi_colors = [8]Color{
    Color.black,
    Color.red,
    Color.green,
    Color.brown,
    Color.blue,
    Color.magenta,
    Color.cyan,
    Color.grey,
};

const ansi_bright_colors = [8]Color{
    Color.bright_black,
    Color.bright_red,
    Color.bright_green,
    Color.bright_brown,
    Color.bright_blue,
    Color.bright_magenta,
    Color.bright_cyan,
    Color.bright_grey,
};

// zig fmt: off
const col256 = [_]u32{
    0x000000, 0x00005f, 0x000087, 0x0000af, 0x0000d7, 0x0000ff, 0x005f00, 0x005f5f,
    0x005f87, 0x005faf, 0x005fd7, 0x005fff, 0x008700, 0x00875f, 0x008787, 0x0087af,
    0x0087d7, 0x0087ff, 0x00af00, 0x00af5f, 0x00af87, 0x00afaf, 0x00afd7, 0x00afff,
    0x00d700, 0x00d75f, 0x00d787, 0x00d7af, 0x00d7d7, 0x00d7ff, 0x00ff00, 0x00ff5f,
    0x00ff87, 0x00ffaf, 0x00ffd7, 0x00ffff, 0x5f0000, 0x5f005f, 0x5f0087, 0x5f00af,
    0x5f00d7, 0x5f00ff, 0x5f5f00, 0x5f5f5f, 0x5f5f87, 0x5f5faf, 0x5f5fd7, 0x5f5fff,
    0x5f8700, 0x5f875f, 0x5f8787, 0x5f87af, 0x5f87d7, 0x5f87ff, 0x5faf00, 0x5faf5f,
    0x5faf87, 0x5fafaf, 0x5fafd7, 0x5fafff, 0x5fd700, 0x5fd75f, 0x5fd787, 0x5fd7af,
    0x5fd7d7, 0x5fd7ff, 0x5fff00, 0x5fff5f, 0x5fff87, 0x5fffaf, 0x5fffd7, 0x5fffff,
    0x870000, 0x87005f, 0x870087, 0x8700af, 0x8700d7, 0x8700ff, 0x875f00, 0x875f5f,
    0x875f87, 0x875faf, 0x875fd7, 0x875fff, 0x878700, 0x87875f, 0x878787, 0x8787af,
    0x8787d7, 0x8787ff, 0x87af00, 0x87af5f, 0x87af87, 0x87afaf, 0x87afd7, 0x87afff,
    0x87d700, 0x87d75f, 0x87d787, 0x87d7af, 0x87d7d7, 0x87d7ff, 0x87ff00, 0x87ff5f,
    0x87ff87, 0x87ffaf, 0x87ffd7, 0x87ffff, 0xaf0000, 0xaf005f, 0xaf0087, 0xaf00af,
    0xaf00d7, 0xaf00ff, 0xaf5f00, 0xaf5f5f, 0xaf5f87, 0xaf5faf, 0xaf5fd7, 0xaf5fff,
    0xaf8700, 0xaf875f, 0xaf8787, 0xaf87af, 0xaf87d7, 0xaf87ff, 0xafaf00, 0xafaf5f,
    0xafaf87, 0xafafaf, 0xafafd7, 0xafafff, 0xafd700, 0xafd75f, 0xafd787, 0xafd7af,
    0xafd7d7, 0xafd7ff, 0xafff00, 0xafff5f, 0xafff87, 0xafffaf, 0xafffd7, 0xafffff,
    0xd70000, 0xd7005f, 0xd70087, 0xd700af, 0xd700d7, 0xd700ff, 0xd75f00, 0xd75f5f,
    0xd75f87, 0xd75faf, 0xd75fd7, 0xd75fff, 0xd78700, 0xd7875f, 0xd78787, 0xd787af,
    0xd787d7, 0xd787ff, 0xd7af00, 0xd7af5f, 0xd7af87, 0xd7afaf, 0xd7afd7, 0xd7afff,
    0xd7d700, 0xd7d75f, 0xd7d787, 0xd7d7af, 0xd7d7d7, 0xd7d7ff, 0xd7ff00, 0xd7ff5f,
    0xd7ff87, 0xd7ffaf, 0xd7ffd7, 0xd7ffff, 0xff0000, 0xff005f, 0xff0087, 0xff00af,
    0xff00d7, 0xff00ff, 0xff5f00, 0xff5f5f, 0xff5f87, 0xff5faf, 0xff5fd7, 0xff5fff,
    0xff8700, 0xff875f, 0xff8787, 0xff87af, 0xff87d7, 0xff87ff, 0xffaf00, 0xffaf5f,
    0xffaf87, 0xffafaf, 0xffafd7, 0xffafff, 0xffd700, 0xffd75f, 0xffd787, 0xffd7af,
    0xffd7d7, 0xffd7ff, 0xffff00, 0xffff5f, 0xffff87, 0xffffaf, 0xffffd7, 0xffffff,
    0x080808, 0x121212, 0x1c1c1c, 0x262626, 0x303030, 0x3a3a3a, 0x444444, 0x4e4e4e,
    0x585858, 0x626262, 0x6c6c6c, 0x767676, 0x808080, 0x8a8a8a, 0x949494, 0x9e9e9e,
    0xa8a8a8, 0xb2b2b2, 0xbcbcbc, 0xc6c6c6, 0xd0d0d0, 0xdadada, 0xe4e4e4, 0xeeeeee
};

const control_code = std.ascii.control_code;
const esc = control_code.esc;
const bs = control_code.bs;

const convtab_nomod = [_]u8{
    0, esc, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', bs, '\t',
    'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n', 0, 'a', 's',
    'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`', 0, '\\', 'z', 'x', 'c', 'v',
    'b', 'n', 'm', ',', '.', '/', 0, 0, 0, ' ',
};

const convtab_capslock = [_]u8{
    0, esc, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', bs, '\t',
    'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '[', ']', '\n', 0, 'A', 'S',
    'D', 'F', 'G', 'H', 'J', 'K', 'L', ';', '\'', '`', 0, '\\', 'Z', 'X', 'C', 'V',
    'B', 'N', 'M', ',', '.', '/', 0, 0, 0, ' ',
};

const convtab_shift = [_]u8{
    0, esc, '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', bs, '\t',
    'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', '\n', 0, 'A', 'S',
    'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~', 0, '|', 'Z', 'X', 'C', 'V',
    'B', 'N', 'M', '<', '>', '?', 0, 0, 0, ' ',
};

const convtab_shift_capslock = [_]u8{
    0, esc, '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', bs, '\t',
    'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '{', '}', '\n', 0, 'a', 's',
    'd', 'f', 'g', 'h', 'j', 'k', 'l', ':', '"', '~', 0, '|', 'z', 'x', 'c', 'v',
    'b', 'n', 'm', '<', '>', '?', 0, 0, 0, ' '
};
// zig fmt: on

pub fn init(
    allocator: std.mem.Allocator,
    framebuffer: [*]u8,
    width: usize,
    height: usize,
    callback: ?*const CallbackFn,
) !*TTY {
    var tty = try allocator.create(TTY);
    errdefer allocator.destroy(tty);
    @memset(std.mem.asBytes(tty), 0);

    tty.text_fg = default_fg;
    tty.text_bg = default_bg;

    tty.framebuffer = @as([*]u32, @ptrCast(@alignCast(framebuffer)))[0 .. width * height];
    tty.width = width;
    tty.height = height;

    tty.cols = width / font_width;
    tty.rows = height / font_height;
    tty.offset_x = (width % font_width) / 2;
    tty.offset_y = (height % font_height) / 2;

    const screen_size = tty.rows * tty.cols;
    tty.grid = try allocator.alloc(Char, screen_size);
    errdefer allocator.free(tty.grid);
    tty.queue = try std.ArrayListUnmanaged(QueueItem).initCapacity(allocator, screen_size);
    errdefer tty.queue.deinit(allocator);
    tty.map = try allocator.alloc(?*QueueItem, screen_size);
    errdefer allocator.free(tty.map);

    const default_c: Char = .{ .c = ' ', .fg = tty.text_fg, .bg = tty.text_bg };
    @memset(tty.grid, default_c);
    @memset(tty.queue.allocatedSlice(), std.mem.zeroes(QueueItem));
    @memset(tty.map, null);
    @memset(tty.framebuffer, @intFromEnum(default_bg));

    tty.callback = callback orelse dummyCallBack;

    tty.reinit();
    tty.drawCursor();

    return tty;
}

pub fn reinit(self: *TTY) void {
    self.cursor_enabled = true;
    self.scroll_enabled = true;
    self.control_sequence = false;
    self.csi = false;
    self.escape = false;
    self.osc = false;
    self.osc_escape = false;
    self.rrr = false;
    self.discard_next = false;
    self.bold = false;
    self.bg_bold = false;
    self.reverse_video = false;
    self.dec_private = false;
    self.insert_mode = false;
    self.unicode_remaining = 0;
    self.g_select = 0;
    self.charsets[0] = .default;
    self.charsets[1] = .dec_special;
    self.current_charset = 0;
    self.escape_offset = 0;
    self.esc_values = .{};
    self.saved_cursor_x = 0;
    self.saved_cursor_y = 0;
    self.current_fg = null;
    self.current_bg = null;
    self.scroll_top_margin = 0;
    self.scroll_bottom_margin = self.rows;
}

// TODO
pub fn read(self: *TTY, buf: []u8) error{}!usize {
    _ = buf;
    _ = self;
    return 0;
}

pub fn write(self: *TTY, buf: []const u8) error{}!usize {
    for (buf) |char| {
        self.putChar(char);
    }

    self.doubleBufferFlush();
    return buf.len;
}

pub fn reader(tty: *TTY) Reader {
    return .{ .context = tty };
}

pub fn writer(tty: *TTY) Writer {
    return .{ .context = tty };
}

fn dummyCallBack(_: *TTY, _: Callback, _: u64, _: u64, _: u64) void {}

inline fn swapPalette(self: *TTY) void {
    const tmp = self.text_bg;
    self.text_bg = self.text_fg;
    self.text_fg = tmp;
}

fn plotChar(self: *TTY, c: *const Char, _x: usize, _y: usize) void {
    if (_x >= self.cols or _y >= self.rows) return;

    const x = self.offset_x + _x * font_width;
    const y = self.offset_y + _y * font_height;

    const glyph = font[c.c * font_height * font_width ..];
    for (0..font_height) |fy| {
        const fb_line = self.framebuffer[x + (y + fy) * self.width ..];

        for (0..font_width) |fx| {
            const draw = glyph[fy * font_width + fx];
            fb_line[fx] = @intFromEnum(if (draw) c.fg else c.bg);
        }
    }
}

fn plotCharFast(self: TTY, old: *const Char, c: *const Char, _x: usize, _y: usize) void {
    if (_x >= self.cols or _y >= self.rows) return;

    const x = self.offset_x + _x * font_width;
    const y = self.offset_y + _y * font_height;

    const new_glyph = font[c.c * font_height * font_width ..];
    const old_glyph = font[old.c * font_height * font_width ..];
    for (0..font_height) |fy| {
        const fb_line = self.framebuffer[x + (y + fy) * self.width ..];

        for (0..font_width) |fx| {
            const old_draw = old_glyph[fy * font_width + fx];
            const new_draw = new_glyph[fy * font_width + fx];
            if (old_draw != new_draw) {
                fb_line[fx] = @intFromEnum(if (new_draw) c.fg else c.bg);
            }
        }
    }
}

fn pushToQueue(self: *TTY, c: *const Char, x: usize, y: usize) void {
    if (x >= self.cols or y >= self.rows) return;

    const i = y * self.cols + x;
    const queue = self.map[i] orelse blk: {
        if (std.meta.eql(self.grid[i], c.*)) return;
        const q = self.queue.addOneAssumeCapacity();
        q.x = x;
        q.y = y;
        self.map[i] = q;
        break :blk q;
    };
    queue.c = c.*;
}

fn revScroll(self: *TTY) void {
    var i: usize = (self.scroll_bottom_margin - 1) * self.cols - 1;
    while (true) : (i -= 1) {
        const queue = self.map[i];
        const c = if (queue) |q| &q.c else &self.grid[i];
        self.pushToQueue(c, (i + self.cols) % self.cols, (i + self.cols) / self.cols);
        if (i == 0) break;
    }

    // Clear the first line of the screen
    const empty: Char = .{ .c = ' ', .fg = self.text_fg, .bg = self.text_bg };
    for (0..self.cols) |j| {
        self.pushToQueue(&empty, j, self.scroll_top_margin);
    }
}

fn scroll(self: *TTY) void {
    const start = (self.scroll_top_margin + 1) * self.cols;
    const end = self.scroll_bottom_margin * self.cols;
    for (start..end) |i| {
        const queue = self.map[i];
        const c = if (queue) |q| &q.c else &self.grid[i];
        self.pushToQueue(c, (i - self.cols) % self.cols, (i - self.cols) / self.cols);
    }

    // Clear the last line of the screen
    const empty: Char = .{ .c = ' ', .fg = self.text_fg, .bg = self.text_bg };
    for (0..self.cols) |i| {
        self.pushToQueue(&empty, i, self.scroll_bottom_margin - 1);
    }
}

fn clear(self: *TTY, move: bool) void {
    const empty: Char = .{ .c = ' ', .fg = self.text_fg, .bg = self.text_bg };
    for (0..self.rows * self.cols) |i| {
        self.pushToQueue(&empty, i % self.cols, i / self.cols);
    }

    if (move) {
        self.cursor_x = 0;
        self.cursor_y = 0;
    }
}

inline fn setCursorPos(self: *TTY, x: usize, y: usize) void {
    if (x >= self.cols) {
        self.cursor_x = self.cols - 1;
    } else {
        self.cursor_x = x;
    }

    if (y >= self.rows) {
        self.cursor_y = self.rows - 1;
    } else {
        self.cursor_y = y;
    }
}

inline fn getCursorPos(self: *TTY, x: *usize, y: *usize) void {
    x.* = if (self.cursor_x >= self.cols) self.cols - 1 else self.cursor_x;
    y.* = if (self.cursor_y >= self.rows) self.rows - 1 else self.cursor_y;
}

fn moveChar(self: *TTY, new_x: usize, new_y: usize, old_x: usize, old_y: usize) void {
    if (old_x >= self.cols or old_y >= self.rows or new_x >= self.cols or new_y >= self.rows) {
        return;
    }

    const i = old_x + old_y * self.cols;
    const queue = self.map[i];
    const c = if (queue) |q| &q.c else &self.grid[i];
    self.pushToQueue(c, new_x, new_y);
}

fn drawCursor(self: *TTY) void {
    if (self.cursor_x >= self.cols or self.cursor_y >= self.rows) return;

    const i = self.cursor_x + self.cursor_y * self.cols;
    const queue = self.map[i];
    var c = if (queue) |q| q.c else self.grid[i];

    const tmp = c.fg;
    c.fg = c.bg;
    c.bg = tmp;
    self.plotChar(&c, self.cursor_x, self.cursor_y);

    if (queue) |q| {
        self.grid[i] = q.c;
        self.map[i] = null;
    }
}

fn doubleBufferFlush(self: *TTY) void {
    if (self.cursor_enabled) {
        self.drawCursor();
    }

    for (self.queue.items) |q| {
        const offset = q.y * self.cols + q.x;
        if (self.map[offset] == null) continue;

        const old = &self.grid[offset];
        if (q.c.bg == old.bg and q.c.fg == old.fg) {
            self.plotCharFast(old, &q.c, q.x, q.y);
        } else {
            self.plotChar(&q.c, q.x, q.y);
        }
        self.grid[offset] = q.c;
        self.map[offset] = null;
    }

    if ((self.old_cursor_x != self.cursor_x or self.old_cursor_y != self.cursor_y) or !self.cursor_enabled) {
        if (self.old_cursor_x < self.cols and self.old_cursor_y < self.rows) {
            const c = &self.grid[self.old_cursor_x + self.old_cursor_y * self.cols];
            self.plotChar(c, self.old_cursor_x, self.old_cursor_y);
        }
    }

    self.old_cursor_x = self.cursor_x;
    self.old_cursor_y = self.cursor_y;

    self.queue.clearRetainingCapacity();
}

fn rawPutChar(self: *TTY, c: u8) void {
    if (self.cursor_x >= self.cols and (self.cursor_y < self.scroll_bottom_margin - 1 or self.scroll_enabled)) {
        self.cursor_x = 0;
        self.cursor_y += 1;
        if (self.cursor_y == self.scroll_bottom_margin) {
            self.cursor_y -= 1;
            self.scroll();
        }
        if (self.cursor_y >= self.cols) {
            self.cursor_y = self.cols - 1;
        }
    }

    const ch: Char = .{ .c = c, .fg = self.text_fg, .bg = self.text_bg };
    self.pushToQueue(&ch, self.cursor_x, self.cursor_y);
    self.cursor_x += 1;
}

// TODO: remove all those ugly inline functions?
inline fn setTextFg(self: *TTY, fg: usize) void {
    self.text_fg = ansi_colors[fg];
}

inline fn setTextBg(self: *TTY, bg: usize) void {
    self.text_bg = ansi_colors[bg];
}

inline fn setTextFgBright(self: *TTY, fg: usize) void {
    self.text_fg = ansi_bright_colors[fg];
}

inline fn setTextBgBright(self: *TTY, bg: usize) void {
    self.text_bg = ansi_bright_colors[bg];
}

inline fn setTextFgRgb(self: *TTY, fg: u32) void {
    self.text_fg = @enumFromInt(fg);
}

inline fn setTextBgRgb(self: *TTY, bg: u32) void {
    self.text_bg = @enumFromInt(bg);
}

inline fn setTextFgDefault(self: *TTY) void {
    self.text_fg = default_fg;
}

inline fn setTextBgDefault(self: *TTY) void {
    self.text_bg = default_bg;
}

inline fn setTextFgDefaultBright(self: *TTY) void {
    self.text_fg = default_fg_bright;
}

inline fn setTextBgDefaultBright(self: *TTY) void {
    self.text_bg = default_bg_bright;
}

fn selectGraphicRendition(self: *TTY) void {
    const esc_values = self.esc_values.constSlice();

    if (esc_values.len == 0) {
        if (self.reverse_video) {
            self.reverse_video = false;
            self.swapPalette();
        }

        self.bold = false;
        self.bg_bold = false;
        self.current_fg = null;
        self.current_bg = null;
        self.setTextFgDefault();
        self.setTextBgDefault();

        return;
    }

    var i: usize = 0;
    // TODO: reverse_video check everywhere is ugly
    // maybe add that before the switch
    // ```zig
    //     if (self.reverse_video) self.swapPalette();
    //     if (self.reverse_video) self.swapPalette();
    // ```
    while (i < esc_values.len) : (i += 1) switch (esc_values[i]) {
        0 => {
            if (self.reverse_video) {
                self.reverse_video = false;
                self.swapPalette();
            }

            self.bold = false;
            self.bg_bold = false;
            self.current_fg = null;
            self.current_bg = null;
            self.setTextBgDefault();
            self.setTextFgDefault();
        },
        1 => {
            self.bold = true;
            if (self.current_fg) |current_fg| {
                if (!self.reverse_video) {
                    self.setTextFgBright(current_fg);
                } else {
                    self.setTextBgBright(current_fg);
                }
            } else {
                if (!self.reverse_video) {
                    self.setTextFgDefaultBright();
                } else {
                    self.setTextBgDefaultBright();
                }
            }
        },
        5 => {
            self.bg_bold = true;
            if (self.current_bg) |current_bg| {
                if (!self.reverse_video) {
                    self.setTextBgBright(current_bg);
                } else {
                    self.setTextFgBright(current_bg);
                }
            } else {
                if (!self.reverse_video) {
                    self.setTextBgDefaultBright();
                } else {
                    self.setTextFgDefaultBright();
                }
            }
        },
        22 => {
            self.bold = false;
            if (self.current_fg) |current_fg| {
                if (!self.reverse_video) {
                    self.setTextFg(current_fg);
                } else {
                    self.setTextBg(current_fg);
                }
            } else {
                if (!self.reverse_video) {
                    self.setTextFgDefault();
                } else {
                    self.setTextBgDefault();
                }
            }
        },
        25 => {
            self.bg_bold = false;
            if (self.current_bg) |current_bg| {
                if (!self.reverse_video) {
                    self.setTextBg(current_bg);
                } else {
                    self.setTextFg(current_bg);
                }
            } else {
                if (!self.reverse_video) {
                    self.setTextBgDefault();
                } else {
                    self.setTextFgDefault();
                }
            }
        },
        30...37 => {
            const offset = 30;
            self.current_fg = esc_values[i] - offset;

            if (self.reverse_video) {
                if (self.bold) {
                    self.setTextBgBright(esc_values[i] - offset);
                } else {
                    self.setTextBg(esc_values[i] - offset);
                }
            } else {
                if (self.bold) {
                    self.setTextFgBright(esc_values[i] - offset);
                } else {
                    self.setTextFg(esc_values[i] - offset);
                }
            }
        },
        40...47 => {
            const offset = 40;
            self.current_bg = esc_values[i] - offset;

            if (self.reverse_video) {
                if (self.bg_bold) {
                    self.setTextFgBright(esc_values[i] - offset);
                } else {
                    self.setTextFg(esc_values[i] - offset);
                }
            } else {
                if (self.bg_bold) {
                    self.setTextBgBright(esc_values[i] - offset);
                } else {
                    self.setTextBg(esc_values[i] - offset);
                }
            }
        },
        90...97 => {
            const offset = 90;
            self.current_fg = esc_values[i] - offset;

            if (self.reverse_video) {
                self.setTextBgBright(esc_values[i] - offset);
            } else {
                self.setTextFgBright(esc_values[i] - offset);
            }
        },
        100...107 => {
            const offset = 100;
            self.current_bg = esc_values[i] - offset;

            if (self.reverse_video) {
                self.setTextFgBright(esc_values[i] - offset);
            } else {
                self.setTextBgBright(esc_values[i] - offset);
            }
        },
        39 => {
            self.current_fg = null;

            if (!self.reverse_video) {
                if (!self.bold) {
                    self.setTextFgDefault();
                } else {
                    self.setTextFgDefaultBright();
                }
            } else {
                if (!self.bold) {
                    self.setTextBgDefault();
                } else {
                    self.setTextBgDefaultBright();
                }
            }
        },
        49 => {
            self.current_bg = null;

            if (!self.reverse_video) {
                if (!self.bg_bold) {
                    self.setTextBgDefault();
                } else {
                    self.setTextBgDefaultBright();
                }
            } else {
                if (!self.bg_bold) {
                    self.setTextFgDefault();
                } else {
                    self.setTextFgDefaultBright();
                }
            }
        },
        7 => {
            if (!self.reverse_video) {
                self.reverse_video = true;
                self.swapPalette();
            }
        },
        27 => {
            if (self.reverse_video) {
                self.reverse_video = false;
                self.swapPalette();
            }
        },
        38, 48 => {
            const is_fg = esc_values[i] == 38;

            i += 1;
            if (i >= esc_values.len) return;

            switch (esc_values[i]) {
                // RGB
                2 => {
                    if (i + 3 >= esc_values.len) return;

                    var rgb_value: u32 = 0;
                    rgb_value |= esc_values[i + 1] << 16;
                    rgb_value |= esc_values[i + 2] << 8;
                    rgb_value |= esc_values[i + 3];

                    i += 3;

                    if (is_fg) {
                        self.setTextFgRgb(rgb_value);
                    } else {
                        self.setTextBgRgb(rgb_value);
                    }
                },
                // 256 colors
                5 => {
                    i += 1;
                    if (i >= esc_values.len) return;

                    const col = esc_values[i];
                    if (col < 8) {
                        if (is_fg) {
                            self.setTextFg(col);
                        } else {
                            self.setTextBg(col);
                        }
                    } else if (col < 16) {
                        if (is_fg) {
                            self.setTextFgBright(col - 8);
                        } else {
                            self.setTextBgBright(col - 8);
                        }
                    } else {
                        const rgb_value = col256[col - 16];
                        if (is_fg) {
                            self.setTextFgRgb(rgb_value);
                        } else {
                            self.setTextBgRgb(rgb_value);
                        }
                    }
                },
                else => {},
            }
        },
        else => {},
    };
}

// TODO: callback with BoundedArray struct directly?
fn decPrivateParse(self: *TTY, c: u8) void {
    self.dec_private = false;

    if (self.esc_values.len == 0) return;

    var set: bool = undefined;
    switch (c) {
        'h' => set = true,
        'l' => set = false,
        else => return,
    }

    if (self.esc_values.get(0) == 25) {
        self.cursor_enabled = set;
        return;
    }

    self.callback(self, Callback.dec, self.esc_values.len, @intFromPtr(&self.esc_values.buffer), c);
}

// TODO: callback with BoundedArray struct directly?
fn linuxPrivateParse(self: *TTY) void {
    if (self.esc_values.len != 0) {
        self.callback(self, Callback.linux, self.esc_values.len, @intFromPtr(&self.esc_values.buffer), 0);
    }
}

// TODO: callback with BoundedArray struct directly?
fn modeToggle(self: *TTY, c: u8) void {
    if (self.esc_values.len == 0) return;

    var set: bool = undefined;
    switch (c) {
        'h' => set = true,
        'l' => set = false,
        else => return,
    }

    if (self.esc_values.get(0) == 4) {
        self.insert_mode = set;
        return;
    }

    self.callback(self, Callback.mode, self.esc_values.len, @intFromPtr(&self.esc_values.buffer), c);
}

fn oscParse(self: *TTY, c: u8) void {
    if (c == control_code.esc) {
        self.osc_escape = true;
        return;
    }

    if (c == control_code.bel or (self.osc_escape and c == '\\')) {
        self.osc = false;
        self.escape = false;
    }

    self.osc_escape = false;
}

fn controlSequenceParse(self: *TTY, c: u8) void {
    if (self.escape_offset == 2) {
        switch (c) {
            '[' => {
                self.discard_next = true;
                self.control_sequence = false;
                self.escape = false;
                return;
            },
            '?' => {
                self.dec_private = true;
                return;
            },
            else => {},
        }
    }

    if (c >= '0' and c <= '9') {
        if (self.esc_values.len < self.esc_values.capacity()) {
            self.rrr = true;
            // TODO: should be like that
            // const last = self.esc_values.popOrNull() orelse 0;
            // self.esc_values.appendAssumeCapacity(last * 10 + (c - '0'));
            self.esc_values.buffer[self.esc_values.len] *%= 10;
            self.esc_values.buffer[self.esc_values.len] +%= c - '0';
        }

        return;
    }

    if (self.rrr) {
        _ = self.esc_values.addOneAssumeCapacity(); // already modified in the previous if
        self.rrr = false;
        if (c == ';') return;
    } else if (c == ';') {
        self.esc_values.append(0) catch return;
        return;
    }

    const esc_default: u32 = switch (c) {
        'J', 'K', 'q' => 0,
        else => 1,
    };
    @memset(self.esc_values.unusedCapacitySlice(), esc_default);

    if (self.dec_private) {
        self.decPrivateParse(c);
        self.control_sequence = false;
        self.escape = false;
        return;
    }

    self.scroll_enabled = false;
    defer self.scroll_enabled = true;

    var x: usize = undefined;
    var y: usize = undefined;
    self.getCursorPos(&x, &y);
    if (c == 'F' or c == 'E') x = 0;

    const esc_values = self.esc_values.slice();

    switch (c) {
        'F', 'A' => {
            if (esc_values[0] > y) {
                esc_values[0] = @intCast(y);
            }
            var dest_y = y - esc_values[0];
            // zig fmt: off
            if ((self.scroll_top_margin >= dest_y and self.scroll_top_margin <= y) or
                (self.scroll_bottom_margin >= dest_y and self.scroll_bottom_margin <= y)) {
                    if (dest_y < self.scroll_top_margin) {
                        dest_y = self.scroll_top_margin;
                    }
            }
            self.setCursorPos(x, dest_y);
        },
        'E', 'e', 'B' => {
            if (y + esc_values[0] > self.rows - 1) {
                esc_values[0] = @intCast((self.rows - 1) - y);
            }
            var dest_y = y + esc_values[0];
            if ((self.scroll_top_margin >= y and self.scroll_top_margin <= dest_y) or
                (self.scroll_bottom_margin >= y and self.scroll_bottom_margin <= dest_y)) {
                    if (dest_y >= self.scroll_bottom_margin) {
                        dest_y = self.scroll_bottom_margin - 1;
                    }
            }
            // zig fmt: on
            self.setCursorPos(x, dest_y);
        },
        'a', 'C' => {
            if (x + esc_values[0] > self.cols - 1)
                esc_values[0] = @intCast((self.cols - 1) - x);
            self.setCursorPos(x + esc_values[0], y);
        },
        'D' => {
            if (esc_values[0] > x) {
                esc_values[0] = @intCast(x);
            }
            self.setCursorPos(x - esc_values[0], y);
        },
        'c' => self.callback(self, Callback.private_id, 0, 0, 0),
        'd' => {
            esc_values[0] -= 1;
            if (esc_values[0] >= self.rows) {
                esc_values[0] = @intCast(self.rows - 1);
            }
            self.setCursorPos(x, esc_values[0]);
        },
        'G', '`' => {
            esc_values[0] -= 1;
            if (esc_values[0] >= self.cols) {
                esc_values[0] = @intCast(self.cols - 1);
            }
            self.setCursorPos(esc_values[0], y);
        },
        'H', 'f' => {
            esc_values[1] -|= 1;
            esc_values[0] -|= 1;
            if (esc_values[1] >= self.cols) {
                esc_values[1] = @intCast(self.cols - 1);
            }
            if (esc_values[0] >= self.rows) {
                esc_values[0] = @intCast(self.rows - 1);
            }
            self.setCursorPos(esc_values[1], esc_values[0]);
        },
        'T' => {
            for (0..esc_values[0]) |_| {
                self.scroll();
            }
        },
        'S' => {
            const old_scroll_top_margin = self.scroll_top_margin;
            self.scroll_top_margin = y;
            for (0..esc_values[0]) |_| {
                self.revScroll();
            }
            self.scroll_top_margin = old_scroll_top_margin;
        },
        'n' => switch (esc_values[0]) {
            5 => self.callback(self, Callback.status_report, 0, 0, 0),
            6 => self.callback(self, Callback.pos_report, x + 1, y + 1, 0),
            else => {},
        },
        'q' => self.callback(self, Callback.kbd_leds, esc_values[0], 0, 0),
        'J' => switch (esc_values[0]) {
            0 => {
                const rows_remaining = self.rows - (y + 1);
                const cols_diff = self.cols - (x + 1);
                const to_clear = rows_remaining * self.cols + cols_diff + 1;
                for (0..to_clear) |_| {
                    self.rawPutChar(' ');
                }
                self.setCursorPos(x, y);
            },
            1 => {
                self.setCursorPos(0, 0);
                blk: for (0..self.rows) |yc| {
                    for (0..self.cols) |xc| {
                        self.rawPutChar(' ');
                        if (xc == x and yc == y) {
                            self.setCursorPos(x, y);
                            break :blk;
                        }
                    }
                }
            },
            2, 3 => self.clear(false),
            else => {},
        },
        '@' => {
            var i: usize = self.cols - 1;
            while (true) : (i -= 1) {
                self.moveChar(i + esc_values[0], y, i, y);
                self.setCursorPos(i, y);
                self.rawPutChar(' ');
                if (i == x) break;
            }
            self.setCursorPos(x, y);
        },
        'P' => {
            for (x + esc_values[0]..self.cols) |i| {
                self.moveChar(i - esc_values[0], y, i, y);
            }
            self.setCursorPos(self.cols - esc_values[0], y);
            for (0..esc_values[0]) |_| {
                self.rawPutChar(' ');
            }
            self.setCursorPos(x, y);
        },
        'X' => {
            for (0..esc_values[0]) |_| {
                self.rawPutChar(' ');
            }
            self.setCursorPos(x, y);
        },
        'm' => self.selectGraphicRendition(),
        's' => self.getCursorPos(&self.saved_cursor_x, &self.saved_cursor_y),
        'u' => self.setCursorPos(self.saved_cursor_x, self.saved_cursor_y),
        'K' => switch (esc_values[0]) {
            0 => {
                for (x..self.cols) |_| {
                    self.rawPutChar(' ');
                }
                self.setCursorPos(x, y);
            },
            1 => {
                self.setCursorPos(0, y);
                for (0..x) |_| {
                    self.rawPutChar(' ');
                }
            },
            2 => {
                self.setCursorPos(0, y);
                for (0..self.cols) |_| {
                    self.rawPutChar(' ');
                }
                self.setCursorPos(x, y);
            },
            else => {},
        },
        'r' => {
            if (esc_values.len > 0) {
                self.scroll_top_margin = esc_values[0] -| 1;
            } else {
                self.scroll_top_margin = 0;
            }

            if (esc_values.len > 1) {
                self.scroll_bottom_margin = if (esc_values[1] == 0) 1 else esc_values[1];
            } else {
                self.scroll_bottom_margin = self.rows;
            }

            if (self.scroll_top_margin >= self.rows or
                self.scroll_bottom_margin > self.rows or
                self.scroll_top_margin >= (self.scroll_bottom_margin - 1))
            {
                self.scroll_top_margin = 0;
                self.scroll_bottom_margin = self.rows;
            }
            self.setCursorPos(0, 0);
        },
        'l', 'h' => self.modeToggle(c),
        ']' => self.linuxPrivateParse(),
        else => {},
    }

    self.control_sequence = false;
    self.escape = false;
}

fn restoreState(self: *TTY) void {
    self.text_fg = self.saved_state_text_fg;
    self.text_bg = self.saved_state_text_bg;
    self.cursor_x = self.saved_state_cursor_x;
    self.cursor_y = self.saved_state_cursor_y;
    self.bold = self.saved_state_bold;
    self.bg_bold = self.saved_state_bg_bold;
    self.reverse_video = self.saved_state_reverse_video;
    self.current_charset = self.saved_state_current_charset;
    self.current_fg = self.saved_state_current_fg;
    self.current_bg = self.saved_state_current_bg;
}

fn saveState(self: *TTY) void {
    self.saved_state_text_fg = self.text_fg;
    self.saved_state_text_bg = self.text_bg;
    self.saved_state_cursor_x = self.cursor_x;
    self.saved_state_cursor_y = self.cursor_y;
    self.saved_state_bold = self.bold;
    self.saved_state_bg_bold = self.bg_bold;
    self.saved_state_reverse_video = self.reverse_video;
    self.saved_state_current_charset = self.current_charset;
    self.saved_state_current_fg = self.current_fg;
    self.saved_state_current_bg = self.current_bg;
}

fn escapeParse(self: *TTY, c: u8) void {
    self.escape_offset += 1;

    if (self.osc) {
        self.oscParse(c);
        return;
    }

    if (self.control_sequence) {
        self.controlSequenceParse(c);
        return;
    }

    if (self.csi) {
        self.csi = false;
        self.esc_values = .{};
        self.rrr = false;
        self.control_sequence = true;
        return;
    }

    var x: usize = undefined;
    var y: usize = undefined;
    self.getCursorPos(&x, &y);

    switch (c) {
        ']' => {
            self.osc_escape = false;
            self.osc = true;
            return;
        },
        '[' => {
            self.esc_values = .{};
            self.rrr = false;
            self.control_sequence = true;
            return;
        },
        '7' => self.saveState(),
        '8' => self.restoreState(),
        'c' => {
            self.reinit();
            self.clear(true);
        },
        'D' => {
            if (y == self.scroll_bottom_margin - 1) {
                self.scroll();
                self.setCursorPos(x, y);
            } else {
                self.setCursorPos(x, y + 1);
            }
        },
        'E' => {
            if (y == self.scroll_bottom_margin - 1) {
                self.scroll();
                self.setCursorPos(0, y);
            } else {
                self.setCursorPos(0, y + 1);
            }
        },
        'M' => {
            // "Reverse linefeed"
            if (y == self.scroll_top_margin) {
                self.revScroll();
                self.setCursorPos(0, y);
            } else {
                self.setCursorPos(0, y - 1);
            }
        },
        'Z' => self.callback(self, Callback.private_id, 0, 0, 0),
        '(', ')' => self.g_select = c - '\'',
        else => {},
    }

    self.escape = false;
}

fn decSpecialPrint(self: *TTY, c: u8) bool {
    switch (c) {
        '`' => self.rawPutChar(0x04),
        '0' => self.rawPutChar(0xdb),
        '-' => self.rawPutChar(0x18),
        ',' => self.rawPutChar(0x1b),
        '.' => self.rawPutChar(0x19),
        'a' => self.rawPutChar(0xb1),
        'f' => self.rawPutChar(0xf8),
        'g' => self.rawPutChar(0xf1),
        'h' => self.rawPutChar(0xb0),
        'j' => self.rawPutChar(0xd9),
        'k' => self.rawPutChar(0xbf),
        'l' => self.rawPutChar(0xda),
        'm' => self.rawPutChar(0xc0),
        'n' => self.rawPutChar(0xc5),
        'q' => self.rawPutChar(0xc4),
        's' => self.rawPutChar(0x5f),
        't' => self.rawPutChar(0xc3),
        'u' => self.rawPutChar(0xb4),
        'v' => self.rawPutChar(0xc1),
        'w' => self.rawPutChar(0xc2),
        'x' => self.rawPutChar(0xb3),
        'y' => self.rawPutChar(0xf3),
        'z' => self.rawPutChar(0xf2),
        '~' => self.rawPutChar(0xfa),
        '_' => self.rawPutChar(0xff),
        '+' => self.rawPutChar(0x1a),
        '{' => self.rawPutChar(0xe3),
        '}' => self.rawPutChar(0x9c),
        else => return false,
    }

    return true;
}

fn unicodeToCP437(code_point: u64) ?u8 {
    return switch (code_point) {
        0x263a => 1,
        0x263b => 2,
        0x2665 => 3,
        0x2666 => 4,
        0x2663 => 5,
        0x2660 => 6,
        0x2022 => 7,
        0x25d8 => 8,
        0x25cb => 9,
        0x25d9 => 10,
        0x2642 => 11,
        0x2640 => 12,
        0x266a => 13,
        0x266b => 14,
        0x263c => 15,
        0x25ba => 16,
        0x25c4 => 17,
        0x2195 => 18,
        0x203c => 19,
        0x00b6 => 20,
        0x00a7 => 21,
        0x25ac => 22,
        0x21a8 => 23,
        0x2191 => 24,
        0x2193 => 25,
        0x2192 => 26,
        0x2190 => 27,
        0x221f => 28,
        0x2194 => 29,
        0x25b2 => 30,
        0x25bc => 31,

        0x2302 => 127,
        0x00c7 => 128,
        0x00fc => 129,
        0x00e9 => 130,
        0x00e2 => 131,
        0x00e4 => 132,
        0x00e0 => 133,
        0x00e5 => 134,
        0x00e7 => 135,
        0x00ea => 136,
        0x00eb => 137,
        0x00e8 => 138,
        0x00ef => 139,
        0x00ee => 140,
        0x00ec => 141,
        0x00c4 => 142,
        0x00c5 => 143,
        0x00c9 => 144,
        0x00e6 => 145,
        0x00c6 => 146,
        0x00f4 => 147,
        0x00f6 => 148,
        0x00f2 => 149,
        0x00fb => 150,
        0x00f9 => 151,
        0x00ff => 152,
        0x00d6 => 153,
        0x00dc => 154,
        0x00a2 => 155,
        0x00a3 => 156,
        0x00a5 => 157,
        0x20a7 => 158,
        0x0192 => 159,
        0x00e1 => 160,
        0x00ed => 161,
        0x00f3 => 162,
        0x00fa => 163,
        0x00f1 => 164,
        0x00d1 => 165,
        0x00aa => 166,
        0x00ba => 167,
        0x00bf => 168,
        0x2310 => 169,
        0x00ac => 170,
        0x00bd => 171,
        0x00bc => 172,
        0x00a1 => 173,
        0x00ab => 174,
        0x00bb => 175,
        0x2591 => 176,
        0x2592 => 177,
        0x2593 => 178,
        0x2502 => 179,
        0x2524 => 180,
        0x2561 => 181,
        0x2562 => 182,
        0x2556 => 183,
        0x2555 => 184,
        0x2563 => 185,
        0x2551 => 186,
        0x2557 => 187,
        0x255d => 188,
        0x255c => 189,
        0x255b => 190,
        0x2510 => 191,
        0x2514 => 192,
        0x2534 => 193,
        0x252c => 194,
        0x251c => 195,
        0x2500 => 196,
        0x253c => 197,
        0x255e => 198,
        0x255f => 199,
        0x255a => 200,
        0x2554 => 201,
        0x2569 => 202,
        0x2566 => 203,
        0x2560 => 204,
        0x2550 => 205,
        0x256c => 206,
        0x2567 => 207,
        0x2568 => 208,
        0x2564 => 209,
        0x2565 => 210,
        0x2559 => 211,
        0x2558 => 212,
        0x2552 => 213,
        0x2553 => 214,
        0x256b => 215,
        0x256a => 216,
        0x2518 => 217,
        0x250c => 218,
        0x2588 => 219,
        0x2584 => 220,
        0x258c => 221,
        0x2590 => 222,
        0x2580 => 223,
        0x03b1 => 224,
        0x00df => 225,
        0x0393 => 226,
        0x03c0 => 227,
        0x03a3 => 228,
        0x03c3 => 229,
        0x00b5 => 230,
        0x03c4 => 231,
        0x03a6 => 232,
        0x0398 => 233,
        0x03a9 => 234,
        0x03b4 => 235,
        0x221e => 236,
        0x03c6 => 237,
        0x03b5 => 238,
        0x2229 => 239,
        0x2261 => 240,
        0x00b1 => 241,
        0x2265 => 242,
        0x2264 => 243,
        0x2320 => 244,
        0x2321 => 245,
        0x00f7 => 246,
        0x2248 => 247,
        0x00b0 => 248,
        0x2219 => 249,
        0x00b7 => 250,
        0x221a => 251,
        0x207f => 252,
        0x00b2 => 253,
        0x25a0 => 254,

        else => null,
    };
}

fn putChar(self: *TTY, c: u8) void {
    if (self.discard_next or (c == control_code.can or c == control_code.sub)) {
        self.discard_next = false;
        self.escape = false;
        self.csi = false;
        self.control_sequence = false;
        self.unicode_remaining = 0;
        self.osc = false;
        self.osc_escape = false;
        self.g_select = 0;
        return;
    }

    if (self.unicode_remaining != 0) blk: {
        if ((c & 0xc0) != 0x80) {
            self.unicode_remaining = 0;
            break :blk;
        }

        self.unicode_remaining -= 1;
        self.code_point |= @as(u64, c & 0x3f) << @intCast(6 * self.unicode_remaining);
        if (self.unicode_remaining != 0) return;

        self.rawPutChar(unicodeToCP437(self.code_point) orelse 0xfe);

        return;
    }

    if (c >= 0xc0 and c <= 0xf7) {
        if (c >= 0xc0 and c <= 0xdf) {
            self.unicode_remaining = 1;
            self.code_point = @as(u64, c & 0x1f) << 6;
        } else if (c >= 0xe0 and c <= 0xef) {
            self.unicode_remaining = 2;
            self.code_point = @as(u64, c & 0x0f) << (6 * 2);
        } else if (c >= 0xf0 and c <= 0xf7) {
            self.unicode_remaining = 3;
            self.code_point = @as(u64, c & 0x07) << (6 * 3);
        }

        return;
    }

    if (self.escape) {
        self.escapeParse(c);
        return;
    }

    if (self.g_select != 0) {
        self.g_select -= 1;
        switch (c) {
            'B' => self.charsets[self.g_select] = .default,
            '0' => self.charsets[self.g_select] = .dec_special,
            else => {},
        }
        self.g_select = 0;
        return;
    }

    var x: usize = undefined;
    var y: usize = undefined;
    self.getCursorPos(&x, &y);

    switch (c) {
        control_code.nul, control_code.del => return,
        0x9b => {
            self.csi = true;
            self.escape_offset = 0;
            self.escape = true;
            return;
        },
        control_code.esc => {
            self.escape_offset = 0;
            self.escape = true;
            return;
        },
        control_code.ht => {
            if ((x / tab_size + 1) >= self.cols) {
                self.setCursorPos(self.cols - 1, y);
                return;
            }
            self.setCursorPos((x / tab_size + 1) * tab_size, y);
            return;
        },
        control_code.vt, control_code.ff, control_code.lf => {
            if (y == self.scroll_bottom_margin - 1) {
                self.scroll();
                self.setCursorPos(0, y);
            } else {
                self.setCursorPos(0, y + 1);
            }
            return;
        },
        control_code.bs => {
            self.setCursorPos(x -| 1, y);
            return;
        },
        control_code.cr => {
            self.setCursorPos(0, y);
            return;
        },
        control_code.bel => {
            self.callback(self, Callback.bell, 0, 0, 0);
            return;
        },
        control_code.so => {
            self.current_charset = 1; // Move to G1 set
            return;
        },
        control_code.si => {
            self.current_charset = 0; // Move to G0 set
            return;
        },
        else => {},
    }

    if (self.insert_mode) {
        var i: usize = self.cols - 1;
        while (true) : (i -= 1) {
            self.moveChar(i + 1, y, i, y);
            if (i == x) break;
        }
    }

    // Translate character set
    switch (self.charsets[self.current_charset]) {
        .default => {},
        .dec_special => if (self.decSpecialPrint(c)) return,
    }

    if (c >= 0x20 and c <= 0x7e) {
        self.rawPutChar(c);
    }
}

// TODO: unfinished + doesn't work well yet + should be somewhere else
pub fn keyboardHandler(self: *TTY) noreturn {
    const ev = @import("event.zig");
    const ps2 = @import("ps2.zig");

    while (true) {
        var events = [_]*ev.Event{&ev.int_events[ps2.keyboard_vector]};
        _ = ev.awaitEvents(events[0..], true);
        self.readKey(ps2.read());
    }
}

// TODO: tell kernel to grab input instead of doing it like that
//       also do the things instead of using term.zig
pub fn readKey(self: *TTY, input: u8) void {
    if (input == 0xe0) {
        self.extra_scancodes = true;
        return;
    }

    if (self.extra_scancodes) {
        self.extra_scancodes = false;

        switch (@as(ScanCode, @enumFromInt(input))) {
            .ctrl => {
                self.ctrl_active = true;
                return;
            },
            .ctrl_rel => {
                self.ctrl_active = false;
                return;
            },
            .keypad_enter => {
                _ = try self.write("\n");
                return;
            },
            .keypad_slash => {
                _ = try self.write("/");
                return;
            },
            // TODO for arrows we could also output A, B, C or D depending on termios settings
            .arrow_up => {
                try term.cursorUp(self.writer(), 1);
                return;
            },
            .arrow_left => {
                try term.cursorBackward(self.writer(), 1);
                return;
            },
            .arrow_down => {
                try term.cursorDown(self.writer(), 1);
                return;
            },
            .arrow_right => {
                try term.cursorForward(self.writer(), 1);
                return;
            },
            .insert, .home, .end, .pgup, .pgdown, .delete => return,
            else => {},
        }
    }

    switch (@as(ScanCode, @enumFromInt(input))) {
        .shift_left, .shift_right => {
            self.shift_active = true;
            return;
        },
        .shift_left_rel, .shift_right_rel => {
            self.shift_active = false;
            return;
        },
        .ctrl => {
            self.ctrl_active = true;
            return;
        },
        .ctrl_rel => {
            self.ctrl_active = false;
            return;
        },
        .capslock => {
            self.capslock_active = !self.capslock_active;
            return;
        },
        else => {},
    }

    var c: u8 = undefined;

    if (input >= 0x3b) return; // TODO F1-F12 + keypad pressed

    if (!self.capslock_active) {
        if (!self.shift_active) {
            c = convtab_nomod[input];
        } else {
            c = convtab_shift[input];
        }
    } else {
        if (!self.shift_active) {
            c = convtab_capslock[input];
        } else {
            c = convtab_shift_capslock[input];
        }
    }

    if (self.ctrl_active) {
        c = std.ascii.toUpper(c) -% 0x40;
    }

    _ = try self.write(&[1]u8{c});
}
