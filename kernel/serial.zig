//! https://en.wikibooks.org/wiki/Serial_Programming/8250_UART_Programming
//! https://wiki.osdev.org/Serial_Ports

const std = @import("std");
const arch = @import("root").arch;
const SpinLock = @import("root").SpinLock;
const log = std.log.scoped(.serial);

pub const Port = enum(u16) {
    com1 = 0x3f8,
    // com2 = 0x2f8,
    // com3 = 0x3e8,
    // com4 = 0x2e8,
    // com5 = 0x5f8,
    // com6 = 0x4f8,
    // com7 = 0x5e8,
    // com8 = 0x4e8,
};

pub var writer: std.Io.Writer = .{
    .vtable = &.{ .drain = drain },
    .buffer = &.{},
};

pub fn print(comptime fmt: []const u8, args: anytype) void {
    writer.print(fmt, args) catch unreachable;
}

pub fn init() void {
    inline for (comptime std.enums.values(Port)) |port| {
        if (initPort(@intFromEnum(port))) {
            log.info("init {}: success", .{port});
        } else {
            log.warn("init {}: fail", .{port});
        }
    }
}

fn initPort(port: u16) bool {
    arch.out(u8, port + 1, 0); // disable all interrupts
    arch.out(u8, port + 3, 0b10000000); // enable DLAB (set baud rate divisor)
    arch.out(u8, port + 0, 1); // set divisor to 1 (lo byte) 115200 baud
    arch.out(u8, port + 1, 0); //                  (hi byte)
    arch.out(u8, port + 3, 0b00000011); // 8 bits, no parity, one stop bit
    arch.out(u8, port + 2, 0b11000111); // enable FIFO with LSR and interrupt flag

    arch.out(u8, port + 4, 0b11110); // set in loopback mode to test the serial chip
    arch.out(u8, port + 0, 0xd); // send byte 0xd and check if serial returns same byte
    if (arch.in(u8, port + 0) != 0xd) return false;

    // if serial is not faulty set everything but loopback
    arch.out(u8, port + 4, 0b01111);

    return true;
}

inline fn transmitterIsEmpty(port: Port) bool {
    return arch.in(u8, @intFromEnum(port) + 5) & 0b01000000 != 0;
}

inline fn transmitData(port: Port, value: u8) void {
    while (!transmitterIsEmpty(port)) {
        std.atomic.spinLoopHint();
    }
    arch.out(u8, @intFromEnum(port), value);
}

fn drain(_: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    var written: usize = 0;
    for (data[0 .. data.len - 1]) |str| {
        for (str) |char| transmitData(.com1, char);
        written += str.len;
    }
    const pattern = data[data.len - 1];
    for (0..splat) |_| {
        for (pattern) |char| transmitData(.com1, char);
        written += pattern.len;
    }
    return written;
}
