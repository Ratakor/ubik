//! https://wiki.osdev.org/PIT

const std = @import("std");
const arch = @import("arch.zig");
const cpu = @import("cpu.zig");
const idt = @import("idt.zig");
const apic = @import("apic.zig");

pub const dividend = 1_193_182;
const timer_freq = 1000;

pub fn init() void {
    setFrequency(timer_freq);
    const timer_vector = idt.allocateVector();
    idt.registerHandler(timer_vector, timerHandler);
    apic.setIRQRedirect(cpu.bsp_lapic_id, timer_vector, 0);
}

pub fn getCurrentCount() u16 {
    arch.out(u8, 0x43, 0);
    const lo = arch.in(u8, 0x40);
    const hi = arch.in(u8, 0x40);
    return (@as(u16, @intCast(hi)) << 8) | lo;
}

pub fn setFrequency(divisor: u64) void {
    var count: u16 = @truncate(dividend / divisor);
    if (dividend % divisor > divisor / 2) {
        count += 1;
    }

    // channel 0, lo/hi access mode, mode 2 (rate generator)
    arch.out(u8, 0x43, 0b00_11_010_0);
    arch.out(u8, 0x40, @truncate(count));
    arch.out(u8, 0x40, @truncate(count >> 8));
}

fn timerHandler(ctx: *cpu.Context) void {
    _ = ctx;

    @import("tty.zig").write(".");
    // TODO time.timerHandler();
    apic.eoi();
}
