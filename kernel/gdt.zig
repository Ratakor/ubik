const std = @import("std");
const limine = @import("limine");
const root = @import("root");
const tty = @import("tty.zig");

const GDTEntry = packed struct {
    limit_low: u16 = 0,
    base_low: u16 = 0,
    base_mid: u8 = 0,
    access: u8 = 0,
    limit_high: u4 = 0,
    flags: u4 = 0,
    base_high: u8 = 0,
};

const TSS = extern struct {
    length: u16,
    base_low: u16,
    base_mid: u8,
    flags1: u8,
    flags2: u8,
    base_high: u8,
    base_upper: u32,
    reserved: u32,
};

const GDT = extern struct {
    descriptors: [11]GDTEntry,
    tss: TSS,
};

const GDTDescriptor = extern struct {
    limit: u16 align(1),
    base: u64 align(1),
};

var gdtr: GDTDescriptor = undefined;
var gdt: GDT = blk: {
    var _gdt: GDT = undefined;
    // Null descriptor.
    _gdt.descriptors[0].limit_low = 0;
    _gdt.descriptors[0].base_low = 0;
    _gdt.descriptors[0].base_mid = 0;
    _gdt.descriptors[0].access = 0;
    _gdt.descriptors[0].limit_high = 0;
    _gdt.descriptors[0].flags = 0;
    _gdt.descriptors[0].base_high = 0;

    // Kernel code 16.
    _gdt.descriptors[1].limit_low = 0xffff;
    _gdt.descriptors[1].base_low = 0;
    _gdt.descriptors[1].base_mid = 0;
    _gdt.descriptors[1].access = 0b10011010;
    _gdt.descriptors[1].limit_high = 0;
    _gdt.descriptors[1].flags = 0;
    _gdt.descriptors[1].base_high = 0;

    // Kernel data 16.
    _gdt.descriptors[2].limit_low = 0xffff;
    _gdt.descriptors[2].base_low = 0;
    _gdt.descriptors[2].base_mid = 0;
    _gdt.descriptors[2].access = 0b10010010;
    _gdt.descriptors[2].limit_high = 0;
    _gdt.descriptors[2].flags = 0;
    _gdt.descriptors[2].base_high = 0;

    // Kernel code 32.
    _gdt.descriptors[3].limit_low = 0xffff;
    _gdt.descriptors[3].base_low = 0;
    _gdt.descriptors[3].base_mid = 0;
    _gdt.descriptors[3].access = 0b10011010;
    _gdt.descriptors[3].limit_high = 0b1100;
    _gdt.descriptors[3].flags = 0b1111;
    _gdt.descriptors[3].base_high = 0;

    // Kernel data 32.
    _gdt.descriptors[4].limit_low = 0xffff;
    _gdt.descriptors[4].base_low = 0;
    _gdt.descriptors[4].base_mid = 0;
    _gdt.descriptors[4].access = 0b10010010;
    _gdt.descriptors[4].limit_high = 0b1100;
    _gdt.descriptors[4].flags = 0b1111;
    _gdt.descriptors[4].base_high = 0;

    // Kernel code 64.
    _gdt.descriptors[5].limit_low = 0;
    _gdt.descriptors[5].base_low = 0;
    _gdt.descriptors[5].base_mid = 0;
    _gdt.descriptors[5].access = 0b10011010;
    _gdt.descriptors[5].limit_high = 0b0010;
    _gdt.descriptors[5].flags = 0;
    _gdt.descriptors[5].base_high = 0;

    // Kernel data 64.
    _gdt.descriptors[6].limit_low = 0;
    _gdt.descriptors[6].base_low = 0;
    _gdt.descriptors[6].base_mid = 0;
    _gdt.descriptors[6].access = 0b10010010;
    _gdt.descriptors[6].limit_high = 0;
    _gdt.descriptors[6].flags = 0;
    _gdt.descriptors[6].base_high = 0;

    // SYSENTER related dummy entries
    _gdt.descriptors[7].limit_low = 0;
    _gdt.descriptors[7].base_low = 0;
    _gdt.descriptors[7].base_mid = 0;
    _gdt.descriptors[7].access = 0;
    _gdt.descriptors[7].limit_high = 0;
    _gdt.descriptors[7].flags = 0;
    _gdt.descriptors[7].base_high = 0;

    _gdt.descriptors[8].limit_low = 0;
    _gdt.descriptors[8].base_low = 0;
    _gdt.descriptors[8].base_mid = 0;
    _gdt.descriptors[8].access = 0;
    _gdt.descriptors[8].limit_high = 0;
    _gdt.descriptors[8].flags = 0;
    _gdt.descriptors[8].base_high = 0;

    // User code 64.
    _gdt.descriptors[9].limit_low = 0;
    _gdt.descriptors[9].base_low = 0;
    _gdt.descriptors[9].base_mid = 0;
    _gdt.descriptors[9].access = 0b11111010;
    _gdt.descriptors[9].limit_high = 0b0010;
    _gdt.descriptors[9].flags = 0;
    _gdt.descriptors[9].base_high = 0;

    // User data 64.
    _gdt.descriptors[10].limit_low = 0;
    _gdt.descriptors[10].base_low = 0;
    _gdt.descriptors[10].base_mid = 0;
    _gdt.descriptors[10].access = 0b11110010;
    _gdt.descriptors[10].limit_high = 0;
    _gdt.descriptors[10].flags = 0;
    _gdt.descriptors[10].base_high = 0;

    // TSS.
    _gdt.tss.length = 104;
    _gdt.tss.base_low = 0;
    _gdt.tss.base_mid = 0;
    _gdt.tss.flags1 = 0b10001001;
    _gdt.tss.flags2 = 0;
    _gdt.tss.base_high = 0;
    _gdt.tss.base_upper = 0;
    _gdt.tss.reserved = 0;

    break :blk _gdt;
};

pub fn init() void {
    gdtr.limit = @sizeOf(GDT) - 1;
    gdtr.base = @intFromPtr(&gdt);

    // asm volatile (
    //     \\lgdt (%[gdtr])
    //     // \\ltr %[tss_sel]
    //     :
    //     : [gdtr] "r" (&gdtr),
    //       // [tss_sel] "r" (@as(u16, 0x48)),
    // );

    // asm volatile (
    //     "lgdt %0\n\t"
    //     "push $0x28\n\t"
    //     "lea 1f(%%rip), %%rax\n\t"
    //     "push %%rax\n\t"
    //     "lretq\n\t"
    //     "1:\n\t"
    //     "mov $0x30, %%eax\n\t"
    //     "mov %%eax, %%ds\n\t"
    //     "mov %%eax, %%es\n\t"
    //     "mov %%eax, %%fs\n\t"
    //     "mov %%eax, %%gs\n\t"
    //     "mov %%eax, %%ss\n\t"
    //     :
    //     : "m"(gdtr)
    //     : "rax", "memory"
    // );
}
