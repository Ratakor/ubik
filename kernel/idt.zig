const std = @import("std");
const limine = @import("limine");
const root = @import("root");
const tty = @import("tty.zig");

const interrupt_gate = 0b1000_1110;
const trap_gate = 0b1000_1111;

const InterruptHandler = fn () callconv(.Naked) void;

const IDTEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8 = 0,
    type_attributes: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32 = 0,
};

const IDTRegister = extern struct {
    limit: u16 align(1),
    base: u64 align(1),
};

var idtr: IDTRegister = .{
    .limit = @sizeOf(@TypeOf(idt)) - 1,
    .base = undefined,
};

var idt: [256]IDTEntry = undefined;
// pub var isr: [256]*const anyopaque = undefined;
// extern void *isr_thunks[];
pub var panic_ipi_vector: u8 = undefined;
// var lock: SpinLock = SPINKLOCK_INIT;
var free_vector: u8 = 32;

// extern fn panic_ipi_entry() callconv (.Naked) void;

pub fn init() void {
    panic_ipi_vector = allocateVector();

    // TODO
    for (0..256) |i| {
        if (i == panic_ipi_vector) {
            // setHandler(@intCast(i), interrupt_gate, @ptrCast(&panic_ipi_entry));
        } else {
            // setHandler(i, interrupt_gate, isr_thunks[i]);
            // isr[i] = genericIsr;
        }
    }

    idtReload();
}

fn allocateVector() u8 {
    // TODO: lock.acquire defer lock.release

    if (free_vector == 0xf0) {
        @panic("IDT exhausted");
    }

    const ret = free_vector;
    free_vector += 1;

    return ret;
}

// TODO
fn setHandler(vector: u8, attributes: u8, handler: *const InterruptHandler) void {
    const handler_int = @intFromPtr(handler);

    idt[vector] = .{
        .offset_low = @truncate(handler_int),
        .selector = 0x08, // gdt kernel code
        .type_attributes = attributes,
        .offset_mid = @truncate(handler_int >> 16),
        .offset_high = @truncate(handler_int >> 32),
    };
}

fn idtReload() void {
    idtr.base = @intFromPtr(&idt);
    asm volatile ("lidt (%[idtr])"
        :
        : [idtr] "r" (&idtr),
        : "memory"
    );
}
