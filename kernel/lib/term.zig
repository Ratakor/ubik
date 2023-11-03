const std = @import("std");
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

    pub inline fn setFg(writer: anytype, fg: Color) !void {
        try writer.print(csi ++ "{d}m", .{@intFromEnum(fg)});
    }

    pub inline fn setBg(writer: anytype, bg: Color) !void {
        try writer.print(csi ++ "{d}m", .{@intFromEnum(bg) + 10});
    }
};

pub const Color256 = enum {
    pub inline fn setFg(writer: anytype, fg: u8) !void {
        try writer.print(csi ++ "38;5;{d}m", .{fg});
    }

    pub inline fn setBg(writer: anytype, bg: u8) !void {
        try writer.print(csi ++ "48;5;{d}m", .{bg});
    }
};

pub const ColorRGB = struct {
    r: u8,
    g: u8,
    b: u8,

    pub inline fn setFg(writer: anytype, fg: ColorRGB) !void {
        try writer.print(csi ++ "38;2;{d};{d};{d}m", .{ fg.r, fg.g, fg.b });
    }

    pub inline fn setBg(writer: anytype, bg: ColorRGB) !void {
        try writer.print(csi ++ "48;2;{d};{d};{d}m", .{ bg.r, bg.g, bg.b });
    }

    pub inline fn setFgStr(comptime str: []const u8) !void {
        try setFg(parse(str));
    }

    pub inline fn setBgStr(comptime str: []const u8) !void {
        try setBg(parse(str));
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

pub inline fn resetColor(writer: anytype) !void {
    try writer.writeAll(csi ++ "m");
}

pub inline fn clearCurrentLine(writer: anytype) !void {
    try writer.writeAll(csi ++ "2K");
}

pub inline fn clearFromCursorToLineBeginning(writer: anytype) !void {
    try writer.writeAll(csi ++ "1K");
}

pub inline fn clearFromCursorToLineEnd(writer: anytype) !void {
    try writer.writeAll(csi ++ "K");
}

pub inline fn clearScreen(writer: anytype) !void {
    try writer.writeAll(csi ++ "2J");
}

pub inline fn clearFromCursorToScreenBeginning(writer: anytype) !void {
    try writer.writeAll(csi ++ "1J");
}

pub inline fn clearFromCursorToScreenEnd(writer: anytype) !void {
    try writer.writeAll(csi ++ "J");
}

pub inline fn hideCursor(writer: anytype) !void {
    try writer.writeAll(csi ++ "?25l");
}

pub inline fn showCursor(writer: anytype) !void {
    try writer.writeAll(csi ++ "?25h");
}

pub inline fn saveCursor(writer: anytype) !void {
    try writer.writeAll(csi ++ "s");
}

pub inline fn restoreCursor(writer: anytype) !void {
    try writer.writeAll(csi ++ "u");
}

pub inline fn cursorUp(writer: anytype, lines: usize) !void {
    try writer.print(csi ++ "{}A", .{lines});
}

pub inline fn cursorDown(writer: anytype, lines: usize) !void {
    try writer.print(csi ++ "{}B", .{lines});
}

pub inline fn cursorForward(writer: anytype, columns: usize) !void {
    try writer.print(csi ++ "{}C", .{columns});
}

pub inline fn cursorBackward(writer: anytype, columns: usize) !void {
    try writer.print(csi ++ "{}D", .{columns});
}

pub inline fn cursorNextLine(writer: anytype, lines: usize) !void {
    try writer.print(csi ++ "{}E", .{lines});
}

pub inline fn cursorPreviousLine(writer: anytype, lines: usize) !void {
    try writer.print(csi ++ "{}F", .{lines});
}

pub inline fn setCursor(writer: anytype, x: usize, y: usize) !void {
    try writer.print(csi ++ "{};{}H", .{ y + 1, x + 1 });
}

pub inline fn setCursorRow(writer: anytype, row: usize) !void {
    try writer.print(csi ++ "{}H", .{row + 1});
}

pub inline fn setCursorColumn(writer: anytype, column: usize) !void {
    try writer.print(csi ++ "{}G", .{column + 1});
}

pub inline fn scrollUp(writer: anytype, lines: usize) !void {
    try writer.print(csi ++ "{}S", .{lines});
}

pub inline fn scrollDown(writer: anytype, lines: usize) !void {
    try writer.print(csi ++ "{}T", .{lines});
}
