//! Host-only tests of the production serial, TTY, terminal and debug modules.
//! buildHostTests uses kernel/test_runner.zig to re-export the mocks below.
const std = @import("std");
const builtin = @import("builtin");
const serial = @import("serial.zig");
const debug = @import("debug.zig");
const TTY = @import("TTY.zig");
pub const term = @import("lib/term.zig");
pub const SpinLock = @import("lock").SpinLock;

pub const arch = struct {
    pub const endian = builtin.cpu.arch.endian();
    var interrupts = true;
    var transmitted: [4096]u8 = undefined;
    var transmitted_len: usize = 0;
    var status_reads: usize = 0;

    pub fn out(comptime T: type, port: u16, value: T) void {
        std.debug.assert(T == u8 and port == @intFromEnum(serial.Port.com1));
        std.debug.assert(transmitted_len < transmitted.len);
        transmitted[transmitted_len] = value;
        transmitted_len += 1;
    }

    pub fn in(comptime T: type, port: u16) T {
        std.debug.assert(T == u8 and port == @intFromEnum(serial.Port.com1) + 5);
        status_reads += 1;
        return 0x40; // UART transmitter empty; no hardware polling.
    }

    pub fn toggleInterrupts(enabled: bool) bool {
        const previous = interrupts;
        interrupts = enabled;
        return previous;
    }

    pub fn disableInterrupts() void {
        interrupts = false;
    }

    pub fn halt() noreturn {
        @panic("host I/O test must not halt");
    }

    fn reset() void {
        interrupts = true;
        transmitted_len = 0;
        status_reads = 0;
    }

    fn output() []const u8 {
        return transmitted[0..transmitted_len];
    }
};

pub const vmm = struct {
    pub fn serviceShootdown() void {
        @panic("unexpected spinlock contention in single-threaded I/O test");
    }
};

pub const time = struct {
    pub var monotonic: struct { sec: u64, nsec: u64 } = .{ .sec = 12, .nsec = 345_000_000 };
};

pub const smp = struct {
    pub fn stopAll() void {
        @panic("host I/O test must not stop CPUs");
    }
};

pub const tty0: ?*TTY = null;
// Only the shape of the bootloader response is needed to compile panic output.
// These tests deliberately use debug.zig's own unknown-DWARF fallback test,
// not a stale kernel ELF or a host-dependent source/symbol address fixture.
pub var kernel_file_request: struct {
    response: ?*const struct { kernel_file: *const struct { address: [*]const u8 } },
} = .{ .response = null };

const TestTTY = struct {
    pixels: []u32,
    tty: *TTY,

    fn init() !TestTTY {
        const width = 180;
        const height = 96;
        const pixels = try std.testing.allocator.alloc(u32, width * height);
        errdefer std.testing.allocator.free(pixels);
        return .{
            .pixels = pixels,
            .tty = try TTY.init(std.testing.allocator, @ptrCast(pixels.ptr), width, height, null),
        };
    }

    fn deinit(self: TestTTY) void {
        std.testing.allocator.free(self.tty.map);
        self.tty.queue.deinit(std.testing.allocator);
        std.testing.allocator.free(self.tty.grid);
        std.testing.allocator.destroy(self.tty);
        std.testing.allocator.free(self.pixels);
    }
};

test "serial writer preserves vector order, splats and byte counts" {
    arch.reset();
    const writer = &serial.writer;
    try std.testing.expectEqual(@as(usize, 9), try writer.writeSplat(&.{ "A", "BC", "de" }, 3));
    try std.testing.expectEqual(@as(usize, 1), try writer.writeSplat(&.{ "F", "ignored" }, 0));
    try writer.splatBytesAll("xy", 2);
    try writer.splatByteAll('!', 3);
    try writer.flush();
    try std.testing.expectEqualStrings("ABCdededeFxyxy!!!", arch.output());
    try std.testing.expectEqual(arch.transmitted_len, arch.status_reads);
    try std.testing.expectEqual(@as(usize, 0), writer.end);
}

test "serial print uses the production formatter" {
    arch.reset();
    serial.print("{s} {d:0>4} 0x{x}", .{ "value", 7, 0x2a });
    try std.testing.expectEqualStrings("value 0007 0x2a", arch.output());
}

test "TTY writer updates the grid immediately and preserves splat order" {
    const fixture = try TestTTY.init();
    defer fixture.deinit();
    const tty = fixture.tty;
    try std.testing.expectEqual(@as(usize, 2), try tty.write("Hi"));
    try std.testing.expectEqual(@as(usize, 9), try tty.writer().writeSplat(&.{ "A", "BC", "de" }, 3));
    try std.testing.expectEqual(@as(usize, 1), try tty.writer().writeSplat(&.{ "F", "ignored" }, 0));
    try tty.writer().print("{d}", .{42});
    try tty.writer().splatByteAll('!', 2);
    const expected = "HiABCdededeF42!!";
    for (expected, 0..) |char, i| try std.testing.expectEqual(char, tty.grid[i].c);
    try std.testing.expectEqual(expected.len, tty.cursor_x);
    try std.testing.expectEqual(@as(usize, 0), tty.writer().end);
    try std.testing.expectEqual(@as(usize, 0), tty.queue.items.len);
    for (tty.map) |entry| try std.testing.expect(entry == null);
}

test "TTY input remains an EOF-only stub without modifying the caller buffer" {
    const fixture = try TestTTY.init();
    defer fixture.deinit();
    var buffer = [_]u8{0xa5} ** 4;
    try std.testing.expectEqual(@as(usize, 0), try fixture.tty.read(&buffer));
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5, 0xa5, 0xa5 }, &buffer);
    try std.testing.expectEqual(@as(usize, 0), try fixture.tty.read(buffer[0..0]));
    try std.testing.expectError(error.EndOfStream, fixture.tty.reader().takeByte());
    try std.testing.expectError(error.EndOfStream, fixture.tty.reader().takeByte());
}

test "TTY consumes terminal escapes and keyboard cursor movement" {
    const fixture = try TestTTY.init();
    defer fixture.deinit();
    const tty = fixture.tty;
    try term.Color.setFg(tty.writer(), .red);
    try term.setCursor(tty.writer(), 3, 2);
    try term.hideCursor(tty.writer());
    try std.testing.expectEqual(@as(u32, 0xaa0000), @intFromEnum(tty.text_fg));
    try std.testing.expectEqual(@as(usize, 3), tty.cursor_x);
    try std.testing.expectEqual(@as(usize, 2), tty.cursor_y);
    try std.testing.expect(!tty.cursor_enabled);
    tty.readKey(0xe0);
    tty.readKey(0x48); // Extended arrow-up scancode.
    try std.testing.expectEqual(@as(usize, 1), tty.cursor_y);
    try term.showCursor(tty.writer());
    try std.testing.expect(tty.cursor_enabled);
}

test "terminal color helpers emit exact ANSI bytes" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try term.Color.setFg(&writer, .bright_red);
    try term.Color.setBg(&writer, .blue);
    try term.Color256.setFg(&writer, 201);
    try term.Color256.setBg(&writer, 17);
    try term.ColorRGB.setFg(&writer, .{ .r = 1, .g = 2, .b = 3 });
    try term.ColorRGB.setBgStr(&writer, "#102030");
    try term.ColorRGB.setFgStr(&writer, "a0b0c0");
    try term.resetColor(&writer);
    try std.testing.expectEqualStrings(
        "\x1b[91m\x1b[44m\x1b[38;5;201m\x1b[48;5;17m" ++
            "\x1b[38;2;1;2;3m\x1b[48;2;16;32;48m\x1b[38;2;160;176;192m\x1b[m",
        writer.buffered(),
    );
}

test "terminal cursor and erase helpers emit exact ANSI bytes" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try term.setCursor(&writer, 3, 2);
    try term.setCursorRow(&writer, 0);
    try term.setCursorColumn(&writer, 4);
    try term.cursorUp(&writer, 1);
    try term.cursorDown(&writer, 2);
    try term.cursorForward(&writer, 3);
    try term.cursorBackward(&writer, 4);
    try term.cursorNextLine(&writer, 5);
    try term.cursorPreviousLine(&writer, 6);
    try term.hideCursor(&writer);
    try term.showCursor(&writer);
    try term.saveCursor(&writer);
    try term.restoreCursor(&writer);
    try term.clearCurrentLine(&writer);
    try term.clearFromCursorToLineBeginning(&writer);
    try term.clearFromCursorToLineEnd(&writer);
    try term.clearScreen(&writer);
    try term.clearFromCursorToScreenBeginning(&writer);
    try term.clearFromCursorToScreenEnd(&writer);
    try term.scrollUp(&writer, 2);
    try term.scrollDown(&writer, 3);
    try std.testing.expectEqualStrings(
        "\x1b[3;4H\x1b[1H\x1b[5G\x1b[1A\x1b[2B\x1b[3C\x1b[4D\x1b[5E\x1b[6F" ++
            "\x1b[?25l\x1b[?25h\x1b[s\x1b[u\x1b[2K\x1b[1K\x1b[K\x1b[2J\x1b[1J\x1b[J\x1b[2S\x1b[3T",
        writer.buffered(),
    );
}

test "terminal helpers propagate bounded writer exhaustion" {
    var buffer: [2]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.WriteFailed, term.hideCursor(&writer));
}

test "debug logging uses the mock clock and releases its production spinlock" {
    arch.reset();
    debug.init();
    defer debug.init();
    debug.log(.info, .io_test, "value {d}", .{42});
    try std.testing.expect(arch.interrupts);
    if (builtin.mode == .Debug) {
        try std.testing.expectEqualStrings("[   12.000345] \x1b[32minfo\x1b[m@io_test: value 42\n", arch.output());
    } else {
        try std.testing.expectEqualStrings("", arch.output());
    }
}

test "production panic output compiles against the host root aliases" {
    // Keep the panic path type-checked without running halt or stopping CPUs.
    std.mem.doNotOptimizeAway(&debug.panic);
}

// Importing the production module retains its frame-iterator, bounded dmesg
// and unknown-DWARF fallback tests; do not duplicate their implementations here.
