//! Shared host runner. Explicit exports expose each harness to kernel root imports.
const std = @import("std");
const harness = @import("harness");

pub const arch = harness.arch;
pub const vmm = harness.vmm;
pub const pmm = if (@hasDecl(harness, "pmm")) harness.pmm else void;
pub const smp = if (@hasDecl(harness, "smp")) harness.smp else void;
pub const sched = if (@hasDecl(harness, "sched")) harness.sched else void;
pub const SpinLock = if (@hasDecl(harness, "SpinLock")) harness.SpinLock else void;
pub const allocator = if (@hasDecl(harness, "allocator")) harness.allocator else void;
pub const term = if (@hasDecl(harness, "term")) harness.term else void;
pub const time = if (@hasDecl(harness, "time")) harness.time else void;
pub const tty0 = if (@hasDecl(harness, "tty0")) harness.tty0 else null;
pub const kernel_file_request = if (@hasDecl(harness, "kernel_file_request")) &harness.kernel_file_request else void;

pub fn main() !void {
    for (@import("builtin").test_functions) |case| {
        std.testing.allocator_instance = .init;
        defer if (std.testing.allocator_instance.deinit() == .leak) @panic("test allocator leak");
        std.debug.print("{s}... ", .{case.name});
        try case.func();
        std.debug.print("OK\n", .{});
    }
}
