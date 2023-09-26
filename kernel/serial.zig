// TODO: mostly useless

const SpinLock = @import("lock.zig").SpinLock;

const com1_port = 0x3f8;
const com_ports = [_]u16{ com1_port, 0x2f8, 0x3e8, 0x2e8 };

var lock: SpinLock = .{};

pub fn init() void {
    for (com_ports) |port| {
        _ = initPort(port);
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

inline fn out(comptime T: type, port: u16, value: T) void {
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

inline fn in(comptime T: type, port: u16) T {
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

inline fn isTransmitterEmpty(port: u16) bool {
    return (in(u8, port + 5) & 0b01000000) != 0;
}

inline fn transmitData(port: u16, value: u8) void {
    while (!isTransmitterEmpty(port)) {
        asm volatile ("pause");
    }
    out(u8, port, value);
}

pub fn outChar(char: u8) void {
    lock.lock();
    defer lock.unlock();

    if (char == '\n') {
        transmitData(com1_port, '\r');
    }
    transmitData(com1_port, char);
}

pub fn outStr(str: []const u8) void {
    lock.lock();
    defer lock.unlock();

    for (str) |char| {
        if (char == '\n') {
            transmitData(com1_port, '\r');
        }
        transmitData(com1_port, char);
    }
}
