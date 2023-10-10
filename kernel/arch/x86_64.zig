pub const CPUID = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

pub inline fn halt() noreturn {
    while (true) asm volatile ("hlt");
}

pub inline fn disableInterrupts() void {
    asm volatile ("cli");
}

pub inline fn enableInterrupts() void {
    asm volatile ("sti");
}

pub inline fn toggleInterrupts(state: bool) bool {
    const old_state = asm volatile (
        \\pushfq
        \\pop %[ret]
        : [ret] "=r" (-> u64),
        :
        : "memory"
    ) & (1 << 9) != 0;
    if (state) enableInterrupts() else disableInterrupts();
    return old_state;
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

pub inline fn readRegister(comptime reg: []const u8) u64 {
    return asm volatile ("mov %%" ++ reg ++ ", %[res]"
        : [res] "=r" (-> u64),
        :
        : "memory"
    );
}

pub inline fn writeRegister(comptime reg: []const u8, value: u64) void {
    asm volatile ("mov %[val], %%" ++ reg
        :
        : [val] "r" (value),
        : "memory"
    );
}

pub inline fn cpuid(leaf: u32, subleaf: u32) CPUID {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile (
        \\cpuid
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (leaf),
          [_] "{ecx}" (subleaf),
    );

    return CPUID{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}
