const std = @import("std");
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
    out(u8, port + 7, 0x69);
    if (in(u8, port + 7) != 0x69) {
        return false;
    }

    out(u8, port + 1, 0x01);
    out(u8, port + 3, 0x80);

    // Set divisor to low 1 high 0 (115200 baud)
    out(u8, port + 0, 0x01);
    out(u8, port + 1, 0x00);

    // Enable FIFO and interrupts
    out(u8, port + 3, 0x03);
    out(u8, port + 2, 0xC7);
    out(u8, port + 4, 0x0b);

    return true;
}

pub inline fn out(comptime T: type, port: u16, value: T) void {
    switch (T) {
        u8 => asm volatile (
            \\outb %[val], %[port]
            :
            : [val] "{al}" (value),
              [port] "N{dx}" (port),
            : "memory"
        ),
        u16 => asm volatile (
            \\outw %[val], %[port]
            :
            : [val] "{ax}" (value),
              [port] "N{dx}" (port),
            : "memory"
        ),
        u32 => asm volatile (
            \\outl %[val], %[port]
            :
            : [val] "{eax}" (value),
              [port] "N{dx}" (port),
            : "memory"
        ),
        else => @compileError("No port out instruction available for type " ++ @typeName(T)),
    }
}

pub inline fn in(comptime T: type, port: u16) T {
    return switch (T) {
        u8 => asm volatile (
            \\inb %[port], %[res]
            : [res] "={al}" (-> T),
            : [port] "N{dx}" (port),
            : "memory"
        ),
        u16 => asm volatile (
            \\inw %[port], %[res]
            : [res] "={ax}" (-> T),
            : [port] "N{dx}" (port),
            : "memory"
        ),
        u32 => asm volatile (
            \\inl %[port], %[res]
            : [res] "={eax}" (-> T),
            : [port] "N{dx}" (port),
            : "memory"
        ),
        else => @compileError("No port in instruction available for type " ++ @typeName(T)),
    };
}

inline fn transmitterIsEmpty(port: Port) bool {
    return in(u8, @intFromEnum(port) + 5) & 0b01000000 != 0;
}

inline fn transmitData(port: Port, value: u8) void {
    while (!transmitterIsEmpty(port)) {
        asm volatile ("pause");
    }
    out(u8, @intFromEnum(port), value);
}

fn com1Write(_: void, str: []const u8) error{}!usize {
    com1_lock.lock();
    defer com1_lock.unlock();

    for (str) |char| {
        transmitData(Port.com1, char);
    }

    return str.len;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    com1_writer.print(fmt, args) catch unreachable;
}
