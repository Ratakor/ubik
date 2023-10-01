const std = @import("std");
const root = @import("root");
const ps2 = @import("ps2.zig");
const SpinLock = @import("lock.zig").SpinLock;
const Terminal = @import("Terminal.zig");

// TODO: termios

const esc = std.ascii.control_code.esc;
const bs = std.ascii.control_code.bs;
const csi = "\x1b[";

// zig fmt: off
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

pub const Color = enum(u8) {
    black = 30,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    default,
    bright_black = 90,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,

    pub inline fn setFg(fg: Color) void {
        print(csi ++ "{d}m", .{@intFromEnum(fg)});
    }

    pub inline fn setBg(bg: Color) void {
        print(csi ++ "{d}m", .{@intFromEnum(bg) + 10});
    }
};

pub const Color256 = enum {
    pub inline fn setFg(fg: u8) void {
        print(csi ++ "38;5;{d}m", .{fg});
    }

    pub inline fn setBg(bg: u8) void {
        print(csi ++ "48;5;{d}m", .{bg});
    }
};

pub const ColorRGB = struct {
    r: u8,
    g: u8,
    b: u8,

    pub inline fn setFg(fg: ColorRGB) void {
        print(csi ++ "38;2;{d};{d};{d}m", .{ fg.r, fg.g, fg.b });
    }

    pub inline fn setBg(bg: ColorRGB) void {
        print(csi ++ "48;2;{d};{d};{d}m", .{ bg.r, bg.g, bg.b });
    }

    pub fn setFgStr(comptime str: []const u8) void {
        setFg(parse(str));
    }

    pub fn setBgStr(comptime str: []const u8) void {
        setBg(parse(str));
    }

    fn parseInt(buf: []const u8) u8 {
        return std.fmt.parseInt(u8, buf, 16) catch @compileError("Invalid rgb color");
    }

    pub fn parse(comptime str: []const u8) ColorRGB {
        const offset = if (str[0] == '#') 1 else 0;
        return comptime .{
            .r = parseInt(str[offset + 0 .. offset + 2]),
            .g = parseInt(str[offset + 2 .. offset + 4]),
            .b = parseInt(str[offset + 4 .. offset + 6]),
        };
    }
};

var terminal: *Terminal = undefined;
var read_lock: SpinLock = .{}; // TODO
var write_lock: SpinLock = .{};
const writer = std.io.Writer(void, error{}, internalWrite){ .context = {} };

pub fn init() !void {
    const fb = root.framebuffer_request.response.?.framebuffers()[0];
    terminal = try Terminal.init(fb.address, fb.width, fb.height, null);
}

fn internalWrite(_: void, str: []const u8) error{}!usize {
    write_lock.lock();
    terminal.write(str);
    write_lock.unlock();
    return str.len;
}

pub inline fn write(bytes: []const u8) void {
    writer.writeAll(bytes) catch unreachable;
}

pub inline fn print(comptime fmt: []const u8, args: anytype) void {
    writer.print(fmt, args) catch unreachable;
}

pub inline fn resetColor() void {
    write(csi ++ "m");
}

pub inline fn clearCurrentLine() void {
    write(csi ++ "2K");
}

pub inline fn clearFromCursorToLineBeginning() void {
    write(csi ++ "1K");
}

pub inline fn clearFromCursorToLineEnd() void {
    write(csi ++ "K");
}

pub inline fn clearScreen() void {
    write(csi ++ "2J");
}

pub inline fn clearFromCursorToScreenBeginning() void {
    write(csi ++ "1J");
}

pub inline fn clearFromCursorToScreenEnd() void {
    write(csi ++ "J");
}

pub inline fn hideCursor() void {
    write(csi ++ "?25l");
}

pub inline fn showCursor() void {
    write(csi ++ "?25h");
}

pub inline fn saveCursor() void {
    write(csi ++ "s");
}

pub inline fn restoreCursor() void {
    write(csi ++ "u");
}

pub inline fn cursorUp(lines: usize) void {
    print(csi ++ "{}A", .{lines});
}

pub inline fn cursorDown(lines: usize) void {
    print(csi ++ "{}B", .{lines});
}

pub inline fn cursorForward(columns: usize) void {
    print(csi ++ "{}C", .{columns});
}

pub inline fn cursorBackward(columns: usize) void {
    print(csi ++ "{}D", .{columns});
}

pub inline fn cursorNextLine(lines: usize) void {
    print(csi ++ "{}E", .{lines});
}

pub inline fn cursorPreviousLine(lines: usize) void {
    print(csi ++ "{}F", .{lines});
}

pub inline fn setCursor(x: usize, y: usize) void {
    print(csi ++ "{};{}H", .{ y + 1, x + 1 });
}

pub inline fn setCursorRow(row: usize) void {
    print(csi ++ "{}H", .{row + 1});
}

pub inline fn setCursorColumn(column: usize) void {
    print(csi ++ "{}G", .{column + 1});
}

pub inline fn scrollUp(lines: usize) void {
    print(csi ++ "{}S", .{lines});
}

pub inline fn scrollDown(lines: usize) void {
    print(csi ++ "{}T", .{lines});
}

pub fn keyboardLoop() void { // TODO noreturn {
    var extra_scancodes = false;
    var ctrl_active = false;
    var shift_active = false;
    var capslock_active = false;

    while (true) {
        const input = ps2.read();

        if (input == 0xe0) {
            extra_scancodes = true;
            continue;
        }

        if (extra_scancodes == true) {
            extra_scancodes = false;

            switch (@as(ScanCode, @enumFromInt(input))) {
                .ctrl => {
                    ctrl_active = true;
                    continue;
                },
                .ctrl_rel => {
                    ctrl_active = false;
                    continue;
                },
                .keypad_enter => {
                    write("\n");
                    continue;
                },
                .keypad_slash => {
                    write("/");
                    continue;
                },
                // TODO for arrows we could also output A, B, C or D depending on settings
                .arrow_up => {
                    cursorUp(1);
                    continue;
                },
                .arrow_left => {
                    cursorBackward(1);
                    continue;
                },
                .arrow_down => {
                    cursorDown(1);
                    continue;
                },
                .arrow_right => {
                    cursorForward(1);
                    continue;
                },
                .insert, .home, .end, .pgup, .pgdown, .delete => continue,
                else => {},
            }
        }

        switch (@as(ScanCode, @enumFromInt(input))) {
            .shift_left, .shift_right => {
                shift_active = true;
                continue;
            },
            .shift_left_rel, .shift_right_rel => {
                shift_active = false;
                continue;
            },
            .ctrl => {
                ctrl_active = true;
                continue;
            },
            .ctrl_rel => {
                ctrl_active = false;
                continue;
            },
            .capslock => {
                capslock_active = !capslock_active;
                continue;
            },
            else => {},
        }

        var c: u8 = undefined;

        if (input >= 0x3b) continue; // TODO F1-F12 + keypad pressed

        if (!capslock_active) {
            if (!shift_active) {
                c = convtab_nomod[input];
            } else {
                c = convtab_shift[input];
            }
        } else {
            if (!shift_active) {
                c = convtab_capslock[input];
            } else {
                c = convtab_shift_capslock[input];
            }
        }

        if (ctrl_active) {
            c = std.ascii.toUpper(c) -% 0x40;
        }

        // TODO: for backspace remove character under cursor?

        if (c == esc) return; // TODO: this is just to have a way to exit

        write(&[1]u8{c});
    }
}
