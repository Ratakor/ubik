//! https://wiki.osdev.org/PIT

const x86 = @import("x86_64.zig");

pub const dividend = 1_193_182;
pub const timer_freq = 1000;

pub fn init() void {
    setFrequency(timer_freq);
}

fn setFrequency(divisor: u64) void {
    var count = dividend / divisor;
    if (dividend % divisor > divisor / 2) {
        count += 1;
    }
    setReloadValue(@truncate(count));
}

pub fn setReloadValue(count: u16) void {
    // channel 0, lo/hi access mode, mode 2 (rate generator)
    x86.out(u8, 0x43, 0b00_11_010_0);
    x86.out(u8, 0x40, @truncate(count));
    x86.out(u8, 0x40, @truncate(count >> 8));
}

pub fn getCurrentCount() u16 {
    x86.out(u8, 0x43, 0);
    const lo = x86.in(u8, 0x40);
    const hi = x86.in(u8, 0x40);
    return (@as(u16, hi) << 8) | lo;
}
