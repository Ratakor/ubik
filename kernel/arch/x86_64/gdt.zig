const SpinLock = @import("root").SpinLock;

/// Global Descriptor Table
const GDT = extern struct {
    null_entry: Entry align(1),
    kernel_code: Entry align(1),
    kernel_data: Entry align(1),
    user_code: Entry align(1),
    user_data: Entry align(1),
    tss: TSS.Descriptor align(1),

    const Entry = packed struct(u64) {
        limit_low: u16 = 0,
        base_low: u16 = 0,
        base_mid: u8 = 0,
        access: u8 = 0,
        limit_high: u4 = 0,
        flags: u4 = 0,
        base_high: u8 = 0,
    };

    const Descriptor = packed struct(u80) {
        limit: u16 = @sizeOf(GDT) - 1,
        base: u64 = undefined,
    };
};

/// Task State Segment
pub const TSS = extern struct {
    reserved0: u32 align(1) = 0,
    rsp0: u64 align(1),
    rsp1: u64 align(1),
    rsp2: u64 align(1),
    reserved1: u64 align(1) = 0,
    ist1: u64 align(1),
    ist2: u64 align(1),
    ist3: u64 align(1),
    ist4: u64 align(1),
    ist5: u64 align(1),
    ist6: u64 align(1),
    ist7: u64 align(1),
    reserved2: u64 align(1) = 0,
    reserved3: u16 align(1) = 0,
    iopb: u16 align(1),

    const Descriptor = packed struct(u128) {
        limit_low: u16 = @sizeOf(TSS),
        base_low: u16 = undefined,
        base_mid: u8 = undefined,
        access: u8 = 0b1000_1001,
        limit_high: u4 = 0,
        flags: u4 = 0,
        base_high: u8 = undefined,
        base_upper: u32 = undefined,
        reserved: u32 = 0,
    };
};

pub const kernel_code = 0x08;
pub const kernel_data = 0x10;
pub const user_code = 0x18;
pub const user_data = 0x20;
pub const tss_descriptor = 0x28;

var gdtr: GDT.Descriptor = .{};
var gdt: GDT = .{
    .null_entry = .{},
    .kernel_code = .{
        .access = 0b1001_1010,
        .flags = 0b1010,
    },
    .kernel_data = .{
        .access = 0b1001_0010,
        .flags = 0b1100,
    },
    .user_code = .{
        .access = 0b1111_1010,
        .flags = 0b1010,
    },
    .user_data = .{
        .access = 0b1111_0010,
        .flags = 0b1100,
    },
    .tss = .{},
};

var tss_lock: SpinLock = .{};

pub fn init() void {
    gdtr.base = @intFromPtr(&gdt);
    reload();
}

pub fn reload() void {
    asm volatile (
        \\lgdt (%[gdtr])
        // reload code segment register
        \\push %[kcode]
        \\lea 1f(%rip), %rax
        \\push %rax
        \\lretq
        \\1:
        // reload other segment registers
        \\mov %[kdata], %ax
        \\mov %ax, %ds
        \\mov %ax, %es
        \\mov %ax, %ss
        :
        : [gdtr] "r" (&gdtr),
          [kcode] "i" (kernel_code),
          [kdata] "i" (kernel_data),
        : "rax", "memory"
    );
}

pub fn loadTSS(tss: *TSS) void {
    tss_lock.lock();
    defer tss_lock.unlock();

    const tss_int = @intFromPtr(tss);

    gdt.tss = .{
        .base_low = @truncate(tss_int),
        .base_mid = @truncate(tss_int >> 16),
        .base_high = @truncate(tss_int >> 24),
        .base_upper = @truncate(tss_int >> 32),
    };

    asm volatile (
        \\ltr %[tss]
        :
        : [tss] "{ax}" (@as(u16, tss_descriptor)),
        : "memory"
    );
}
