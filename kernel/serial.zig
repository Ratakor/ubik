const std = @import("std");
const arch = @import("arch.zig");
const SpinLock = @import("lock.zig").SpinLock;
const log = std.log.scoped(.serial);

pub const Port = enum(u16) {
    com1 = 0x3f8,
    com2 = 0x2f8,
    com3 = 0x3e8,
    com4 = 0x2e8,
};

var com1_lock: SpinLock = .{};
const com1_writer = std.io.Writer(void, error{}, com1Write){ .context = {} };

pub fn print(comptime fmt: []const u8, args: anytype) void {
    com1_writer.print(fmt, args) catch unreachable;
}

pub fn init() void {
    for (std.enums.values(Port)) |port| {
        if (initPort(@intFromEnum(port))) {
            log.info("init {}: success", .{port});
        } else {
            log.warn("init {}: fail", .{port});
        }
    }
}

fn initPort(port: u16) bool {
    // Check if the port exists by writing and read from the scratch register
    arch.out(u8, port + 7, 0x69);
    if (arch.in(u8, port + 7) != 0x69) {
        return false;
    }

    arch.out(u8, port + 1, 0x01);
    arch.out(u8, port + 3, 0x80);

    // Set divisor to low 1 high 0 (115200 baud)
    arch.out(u8, port + 0, 0x01);
    arch.out(u8, port + 1, 0x00);

    // Enable FIFO and interrupts
    arch.out(u8, port + 3, 0x03);
    arch.out(u8, port + 2, 0xC7);
    arch.out(u8, port + 4, 0x0b);

    return true;
}

inline fn transmitterIsEmpty(port: Port) bool {
    return arch.in(u8, @intFromEnum(port) + 5) & 0b01000000 != 0;
}

inline fn transmitData(port: Port, value: u8) void {
    while (!transmitterIsEmpty(port)) {
        asm volatile ("pause");
    }
    arch.out(u8, @intFromEnum(port), value);
}

fn com1Write(_: void, str: []const u8) error{}!usize {
    com1_lock.lock();
    defer com1_lock.unlock();

    for (str) |char| {
        transmitData(Port.com1, char);
    }

    return str.len;
}
