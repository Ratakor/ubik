const assert = @import("std").debug.assert;

pub const Rflags = packed struct {
    CF: u1 = 0,
    reserved: u1 = 1,
    PF: u1 = 0,
    reserved1: u1 = 0,
    AF: u1 = 0,
    reserved2: u1 = 0,
    ZF: u1 = 0,
    SF: u1 = 0,
    TF: u1 = 0,
    IF: u1 = 0,
    DF: u1 = 0,
    OF: u1 = 0,
    IOPL: u2 = 0,
    NT: u1 = 0,
    reserved3: u1 = 0,
    RF: u1 = 0,
    VM: u1 = 0,
    AC: u1 = 0,
    VIF: u1 = 0,
    VIP: u1 = 0,
    ID: u1 = 0,
    reserved4: u42 = 0,

    comptime {
        assert(@sizeOf(Rflags) == @sizeOf(u64));
        assert(@bitSizeOf(Rflags) == @bitSizeOf(u64));
    }
};

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

pub inline fn interruptState() bool {
    return asm volatile (
        \\pushfq
        \\pop %[ret]
        : [ret] "=r" (-> u64),
        :
        : "memory"
    ) & (1 << 9) != 0;
}

pub inline fn toggleInterrupts(state: bool) bool {
    const old_state = interruptState();
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

pub inline fn rdmsr(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile (
        \\rdmsr
        : [_] "={eax}" (low),
          [_] "={edx}" (high),
        : [_] "{ecx}" (msr),
        : "memory"
    );

    return @as(u64, low) | (@as(u64, high) << 32);
}

pub inline fn wrmsr(msr: u32, value: u64) void {
    asm volatile (
        \\wrmsr
        :
        : [_] "{eax}" (@as(u32, @truncate(value))),
          [_] "{edx}" (@as(u32, @truncate(value >> 32))),
          [_] "{ecx}" (msr),
        : "memory"
    );
}

pub inline fn setKernelGsBase(addr: u64) void {
    wrmsr(0xc0000102, addr);
}

pub inline fn setGsBase(addr: u64) void {
    wrmsr(0xc0000101, addr);
}

pub inline fn setFsBase(addr: u64) void {
    wrmsr(0xc0000100, addr);
}

pub inline fn getKernelGsBase() u64 {
    return rdmsr(0xc0000102);
}

pub inline fn getGsBase() u64 {
    return rdmsr(0xc0000101);
}

pub inline fn getFsBase() u64 {
    return rdmsr(0xc0000100);
}

pub inline fn wrxcr(reg: u32, value: u64) void {
    asm volatile (
        \\xsetbv
        :
        : [_] "{eax}" (@as(u32, @truncate(value))),
          [_] "{edx}" (@as(u32, @truncate(value >> 32))),
          [_] "{ecx}" (reg),
        : "memory"
    );
}

pub inline fn xsave(ctx: u64) void {
    asm volatile (
        \\xsave (%[ctx])
        :
        : [ctx] "r" (ctx),
          [_] "{rax}" (~@as(u64, 0)),
          [_] "{rdx}" (~@as(u64, 0)),
        : "memory"
    );
}

pub inline fn xrstor(ctx: u64) void {
    asm volatile (
        \\xrstor (%[ctx])
        :
        : [ctx] "r" (ctx),
          [_] "{rax}" (~@as(u64, 0)),
          [_] "{rdx}" (~@as(u64, 0)),
        : "memory"
    );
}

pub inline fn fxsave(ctx: u64) void {
    asm volatile (
        \\fxsave (%[ctx])
        :
        : [ctx] "r" (ctx),
        : "memory"
    );
}

pub inline fn fxrstor(ctx: u64) void {
    asm volatile (
        \\fxrstor (%[ctx])
        :
        : [ctx] "r" (ctx),
        : "memory"
    );
}

pub inline fn rdseed() u64 {
    return asm volatile (
        \\rdseed %[res]
        : [res] "=r" (-> u64),
    );
}

pub inline fn rdrand() u64 {
    return asm volatile (
        \\rdrand %[res]
        : [res] "=r" (-> u64),
    );
}

pub inline fn invlpg(addr: u64) void {
    asm volatile (
        \\invlpg (%[addr])
        :
        : [addr] "r" (addr),
        : "memory"
    );
}
