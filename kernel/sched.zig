const std = @import("std");
const cpu = @import("cpu.zig");
const idt = @import("idt.zig");
const rand = @import("rand.zig");
const proc = @import("proc.zig");
const Process = proc.Process;
const Thread = proc.Thread;
const log = std.log.scoped(.sched);

pub var kernel_process: *Process = undefined; // TODO

pub fn init() void {
    const sched_vector = idt.allocVector();
    log.info("scheduler interrupt vector is 0x{x}", .{sched_vector});

    rand.init();

    // idt.registerHandler(sched_vector, schedHandler);
    // idt.setIST(sched_vector, 1);
}

pub inline fn currentThread() *Thread {
    return asm volatile (
        \\mov %%gs:0x0, %[thr]
        : [thr] "=r" (-> *Thread),
    );
}

fn schedHandler(ctx: *cpu.Context) void {
    _ = ctx;
}
