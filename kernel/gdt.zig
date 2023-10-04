const log = @import("std").log.scoped(.gdt);
const SpinLock = @import("lock.zig").SpinLock;
const TSS = @import("cpu.zig").TSS;

const GDTEntry = packed struct {
    limit_low: u16 = 0,
    base_low: u16 = 0,
    base_mid: u8 = 0,
    access: u8 = 0,
    limit_high: u4 = 0,
    flags: u4 = 0,
    base_high: u8 = 0,
};

const TSSDescriptor = packed struct {
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

/// Global Descriptor Table
const GDT = extern struct {
    null_entry: GDTEntry align(8),
    kernel_code: GDTEntry align(8),
    kernel_data: GDTEntry align(8),
    user_code: GDTEntry align(8),
    user_data: GDTEntry align(8),
    tss: TSSDescriptor align(8),
};

const GDTDescriptor = extern struct {
    limit: u16 align(1) = @sizeOf(GDT) - 1,
    base: u64 align(1) = undefined,
};

var gdtr: GDTDescriptor = .{};
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
    .tss = .{
        .access = 0b1000_1001,
        .flags = 0,
    },
};
var lock: SpinLock = .{};

pub fn init() void {
    gdtr.base = @intFromPtr(&gdt);
    reloadGDT();
    log.info("init: successfully reloaded GDT", .{});
}

pub fn reloadGDT() void {
    asm volatile (
        \\lgdt (%[gdtr])
        // reload CS register, 0x08 = kernel_code
        \\push $0x08
        \\lea 1f(%%rip), %%rax
        \\push %%rax
        \\lretq
        \\1:
        // reload data segment registers, 0x10 = kernel_data
        \\mov $0x10, %%ax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        \\mov %%ax, %%ss
        :
        : [gdtr] "r" (&gdtr),
        : "rax", "memory"
    );
}

pub fn loadTSS(tss: *TSS) void {
    lock.lock();
    defer lock.unlock();

    const tss_int = @intFromPtr(tss);

    gdt.tss.base_low = tss_int;
    gdt.tss.base_mid = @truncate(tss_int >> 16);
    gdt.tss.base_high = @truncate(tss_int >> 24);
    gdt.tss.base_upper = @truncate(tss_int >> 32);

    asm volatile ("ltr %[tss]"
        :
        : [tss] "r" (0x28),
        : "memory"
    );
}
