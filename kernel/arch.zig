pub inline fn halt() noreturn {
    while (true) asm volatile ("hlt");
}

pub inline fn disableInterrupts() void {
    asm volatile ("cli");
}

pub inline fn enableInterrupts() void {
    asm volatile ("sti");
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
