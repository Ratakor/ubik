const std = @import("std");
const arch = @import("arch.zig");
const pit = @import("pit.zig");
const log = std.log.scoped(.rand);

const Pcg = std.rand.Pcg;
var pcg: Pcg = undefined;
pub const random = pcg.random();

pub fn init() void {
    var seed: u64 = undefined;
    if (arch.cpuid(7, 0).ebx & (@as(u32, 1) << 18) != 0) {
        seed = arch.rdseed();
        log.info("getting seed from rdseed: {}", .{seed});
    } else if (arch.cpuid(1, 0).ecx & (@as(u32, 1) << 30) != 0) {
        seed = arch.rdrand();
        log.info("getting seed from rdrand: {}", .{seed});
    } else {
        seed = @as(u64, @intCast(pit.realtime.tv_sec)) ^ 0x91217df9814032ab;
        log.info("getting seed from current time: {}", .{seed});
    }

    pcg = Pcg.init(seed);
}
