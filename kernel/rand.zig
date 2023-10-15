pub usingnamespace @import("std").rand;
const arch = @import("arch.zig");
const time = @import("time.zig");

pub fn getSeedSlow() u64 {
    if (arch.cpuid(7, 0).ebx & (@as(u32, 1) << 18) != 0) return arch.rdseed();
    if (arch.cpuid(1, 0).ecx & (@as(u32, 1) << 30) != 0) return arch.rdrand();
    return @as(u64, @intCast(time.realtime.tv_sec)) ^ 0x91217df9814032ab;
}
