const std = @import("std");
const arch = @import("arch.zig");
const cpu = @import("cpu.zig");
const idt = @import("idt.zig");
const apic = @import("apic.zig");

pub const dividend = 1193182;

pub fn init() void {
    // TODO setFrequency(time.timer_freq)
    const timer_vector = idt.allocateVector();
    idt.registerHandler(timer_vector, timerHandler);
    apic.setIRQRedirect(cpu.bsp_lapic_id, timer_vector, 0); // TODO: status is true
}

pub fn getCurrentCount() u16 {
    arch.out(u8, 0x43, 0x00);
    // return arch.in(u16, 0x40);
    const lo = arch.in(u8, 0x40);
    const hi = arch.in(u8, 0x40);
    return (@as(u16, @intCast(hi)) << 8) | lo;
}

pub fn setReloadValue(new_count: u16) void {
    // TODO
    // channel 0, lo/hi access mode, mode 2 (rate generator)
    arch.out(u8, 0x43, 0x34);
    // arch.out(u16, 0x40, new_count);
    arch.out(u8, 0x40, @truncate(new_count));
    arch.out(u8, 0x40, @truncate(new_count >> 8));
}

pub fn setFrequency(frequency: u64) void {
    var new_divisor = dividend / frequency;
    if (dividend % frequency > frequency / 2) {
        new_divisor += 1;
    }
    setReloadValue(@intCast(new_divisor));
}

fn timerHandler(ctx: *cpu.Context) void {
    _ = ctx;

    // TODO time.timerHandler();
    apic.eoi();
}
