const std = @import("std");
const root = @import("root");
const SpinLock = @import("lock.zig").SpinLock;
const Terminal = @import("Terminal.zig");

// TODO: termios <- in tty/Terminal ?
// TODO: user_write_lock -> user write on buffer + framebuffer, log user write ???

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

const esc = std.ascii.control_code.esc;
const bs = std.ascii.control_code.bs;

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

var extra_scancodes = false;
var ctrl_active = false;
var shift_active = false;
var capslock_active = false;

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
        else => std.log.warn("unhandled callback: `{}` with args: {}, {}, {}", .{ cb, arg1, arg2, arg3 }),
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

pub fn readKey(input: u8) void {
    const tty = @This();

    if (input == 0xe0) {
        extra_scancodes = true;
        return;
    }

    if (extra_scancodes == true) {
        extra_scancodes = false;

        switch (@as(ScanCode, @enumFromInt(input))) {
            .ctrl => {
                ctrl_active = true;
                return;
            },
            .ctrl_rel => {
                ctrl_active = false;
                return;
            },
            .keypad_enter => {
                tty.write("\n");
                return;
            },
            .keypad_slash => {
                tty.write("/");
                return;
            },
            // TODO for arrows we could also output A, B, C or D depending on termios settings
            .arrow_up => {
                // tty.cursorUp(1);
                return;
            },
            .arrow_left => {
                // tty.cursorBackward(1);
                return;
            },
            .arrow_down => {
                // tty.cursorDown(1);
                return;
            },
            .arrow_right => {
                // tty.cursorForward(1);
                return;
            },
            .insert, .home, .end, .pgup, .pgdown, .delete => return,
            else => {},
        }
    }

    switch (@as(ScanCode, @enumFromInt(input))) {
        .shift_left, .shift_right => {
            shift_active = true;
            return;
        },
        .shift_left_rel, .shift_right_rel => {
            shift_active = false;
            return;
        },
        .ctrl => {
            ctrl_active = true;
            return;
        },
        .ctrl_rel => {
            ctrl_active = false;
            return;
        },
        .capslock => {
            capslock_active = !capslock_active;
            return;
        },
        else => {},
    }

    var c: u8 = undefined;

    if (input >= 0x3b) return; // TODO F1-F12 + keypad pressed

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

    tty.write(&[1]u8{c});
}
