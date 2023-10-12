const std = @import("std");
const cpu = @import("cpu.zig");
const SpinLock = @import("lock.zig").SpinLock;

// TODO: this needs a lot of work

pub const pid_t = std.os.linux.pid_t;
pub const fd_t = std.os.linux.fd_t;
// pub const uid_t = std.os.linux.uid_t;
// pub const gid_t = std.os.linux.gid_t;
// pub const clock_t = std.os.linux.clock_t;

pub const Process = struct {
    pid: pid_t,
    name: []u8,
    parent: ?*Process,
    // ...
};

pub const Thread = struct {
    self: *Thread, // TODO
    errno: usize,

    tid: u32,
    lock: SpinLock,
    this_cpu: *cpu.CpuLocal,
    process: *Process,
    // ...
};

pub fn init() void {}

// pub fn getErrno(r: usize) E {
//     const signed_r = @as(isize, @bitCast(r));
//     const int = if (signed_r > -4096 and signed_r < 0) -signed_r else 0;
//     return @as(E, @enumFromInt(int));
// }
