const std = @import("std");
const root = @import("root");
const SpinLock = @import("lock.zig").SpinLock;
const cpu = @import("cpu.zig");
const idt = @import("idt.zig");
const tty = @import("tty.zig");
const pmm = @import("pmm.zig");

const page_size = std.mem.page_size;
pub const higher_half = root.hhdm_request.response.?.offset;

pub const Flags = enum(u64) {
    present = 1 << 0,
    write = 1 << 1,
    user = 1 << 2,
    large = 1 << 7,
    noexec = 1 << 63,
};

pub fn init() !void {
    const hhdm = root.hhdm_request.response.?.offset;
    const kernel_address = root.kernel_address_request.response.?;
    _ = hhdm;
    _ = kernel_address;

    idt.registerHandler(idt.page_fault_vector, pageFaultHandler);
}

fn switchPageTable(cr3: u64) void {
    asm volatile (
        \\mov %[cr3], %%cr3
        :
        : [cr3] "r" (cr3),
        : "memory"
    );
}

fn pageFaultHandler(ctx: *cpu.Context) void {
    _ = ctx;
    tty.print("TODO: handle Page fault\n", .{});
}
