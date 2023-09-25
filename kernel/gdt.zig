const std = @import("std");
const limine = @import("limine");
const root = @import("root");
const tty = @import("tty.zig");

// https://wiki.osdev.org/Global_Descriptor_Table

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
    length: u16,
    base_low: u16,
    base_mid: u8,
    flags1: u8,
    flags2: u8,
    base_high: u8,
    base_upper: u32,
    reserved: u32,
};

const TSS = extern struct {
    reserved0: u32 align(1) = 0,
    rsp: [3]u64 align(1),
    reserved1: u64 align(1) = 0,
    ist: [7]u64 align(1),
    reserved2: u80 align(1) = 0,
    reserved3: u16 align(1) = 0,
    iopb: u16 align(1),
};

const GDT = extern struct {
    null_entry: GDTEntry align(8),
    kernel_code: GDTEntry align(8),
    kernel_data: GDTEntry align(8),
    user_code: GDTEntry align(8),
    user_data: GDTEntry align(8),
    // tss: TSSDescriptor align(8),
};

const GDTDescriptor = extern struct {
    limit: u16 align(1),
    base: u64 align(1),
};

var gdtr: GDTDescriptor = .{
    .limit = @sizeOf(GDT) - 1,
    .base = undefined,
};

var gdt: GDT = .{
    .null_entry = .{},
    .kernel_code = .{
        .limit_low = 0xffff,
        .limit_high = 0xf,
        .access = 0b10011010,
        .flags = 0b1010,
    },
    .kernel_data = .{
        .limit_low = 0xffff,
        .limit_high = 0xf,
        .access = 0b10010010,
        .flags = 0b1100,
    },
    .user_code = .{
        .limit_low = 0xffff,
        .limit_high = 0xf,
        .access = 0b11111010,
        .flags = 0b1010,
    },
    .user_data = .{
        .limit_low = 0xffff,
        .limit_high = 0xf,
        .access = 0b11110010,
        .flags = 0b1100,
    },
    // .tss = undefined,
};

var tss: TSS = .{
    .rsp = undefined,
    .ist = undefined,
    .iopb = undefined,
};

pub fn init() void {
    gdtr.base = @intFromPtr(&gdt);

    reloadGDT();
}

fn reloadGDT() void {
    asm volatile (
        \\lgdt (%[gdtr])
        // reload CS register
        \\push $0x08
        \\lea 1f(%%rip), %%rax
        \\push %%rax
        \\lretq
        \\1:
        // reload data segment registers
        \\mov $0x10, %%ax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        \\mov %%ax, %%ss
        :
        : [gdtr] "r" (&gdtr)
        : "rax", "memory"
    );
}

// pub fn loadTss(tss: *TSS) void {
//     // TODO: create lock
//     // TODO: lock defer unlock

//     gdt.tss.base_low = @intFromPtr(tss);
//     gdt.tss.base_mid = @truncate(@intFromPtr(tss) >> 16);
//     gdt.tss.flags1 = 0b10001001;
//     gdt.tss.flags2 = 0;
//     gdt.tss.base_high = @truncate(@intFromPtr(tss) >> 24);
//     gdt.tss.base_upper = @truncate(@intFromPtr(tss) >> 32);
//     gdt.tss.reserved = 0;

//     asm volatile ("ltr %[tss]" : : [tss] "r" (0x28) : "memory");
// }
