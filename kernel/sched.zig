const std = @import("std");
const cpu = @import("cpu.zig");
const idt = @import("idt.zig");
const log = std.log.scoped(.sched);

pub fn init() void {
    const sched_vector = idt.allocateVector();
    log.info("scheduler interrupt vector is 0x{x}", .{sched_vector});

    // idt.registerHandler(sched_vector, schedHandler);
    // idt.setIST(sched_vector, 1);
}

fn schedHandler(ctx: *cpu.Context) void {
    _ = ctx;
}
