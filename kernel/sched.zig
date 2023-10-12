const std = @import("std");
const cpu = @import("cpu.zig");
const idt = @import("idt.zig");
const rand = @import("rand.zig");
const log = std.log.scoped(.sched);

pub fn init() void {
    const sched_vector = idt.allocVector();
    log.info("scheduler interrupt vector is 0x{x}", .{sched_vector});

    rand.init();

    // idt.registerHandler(sched_vector, schedHandler);
    // idt.setIST(sched_vector, 1);
}

fn schedHandler(ctx: *cpu.Context) void {
    _ = ctx;
}
