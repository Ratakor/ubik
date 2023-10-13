const std = @import("std");
const smp = @import("smp.zig");
const arch = @import("arch.zig");
const vmm = @import("vmm.zig");
const SpinLock = @import("SpinLock.zig");

// TODO: merge this with sched.zig
// TODO: this needs a lot of work

pub const pid_t = std.os.linux.pid_t;
pub const fd_t = std.os.linux.fd_t;
pub const uid_t = std.os.linux.uid_t;
pub const gid_t = std.os.linux.gid_t;

pub const Process = struct {
    pid: pid_t,
    name: [:0]u8, // [127:0]u8 ?
    parent: ?*Process, // use ppid ?
    addr_space: vmm.AddressSpace,
    // mmap_anon_base: usize,
    // thread_stack_top: usize,
    // cwd: // TODO
    threads: std.ArrayListUnmanaged(*Thread) = .{}, // TODO: use linked list?
    children: std.ArrayListUnmanaged(*Process) = .{},
    // child_events
    // event: ev.Event

    // fds_lock: SpinLock = .{},
    // umask: u32,
    // fds
};

// TODO: extern ?
pub const Thread = struct {
    self: *Thread, // TODO
    errno: usize,

    tid: u32,
    lock: SpinLock = .{},
    this_cpu: *smp.CpuLocal,
    process: *Process,
    ctx: arch.Context,

    scheduling_off: bool,
    running_on: u32,
    enqueued: bool,
    enqueued_by_signal: bool,
    timeslice: u32,
    yield_await: SpinLock = .{},
    gs_base: u64,
    fs_base: u64,
    cr3: u64,
    fpu_storage: u64,
    // ...
};

pub fn init() void {}

// pub fn getErrno(r: usize) E {
//     const signed_r = @as(isize, @bitCast(r));
//     const int = if (signed_r > -4096 and signed_r < 0) -signed_r else 0;
//     return @as(E, @enumFromInt(int));
// }
