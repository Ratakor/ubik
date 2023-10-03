const std = @import("std");
const root = @import("root");
const SpinLock = @import("lock.zig").SpinLock;
const Terminal = @import("Terminal.zig");

const csi = "\x1b[";

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
    terminal = try Terminal.init(fb.address, fb.width, fb.height, callback);
}

fn callback(ctx: *Terminal, cb: Terminal.Callback, arg1: u64, arg2: u64, arg3: u64) void {
    _ = ctx;
    // TODO: https://github.com/limine-bootloader/limine/blob/v5.x-branch/PROTOCOL.md#terminal-callback
    switch (cb) {
        else => std.log.warn("unhandled callback `{}` with args: {}, {}, {}", .{ cb, arg1, arg2, arg3 }),
    }
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
