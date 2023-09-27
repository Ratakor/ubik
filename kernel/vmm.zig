const std = @import("std");
const limine = @import("limine");
const root = @import("root");
const SpinLock = @import("lock.zig").SpinLock;
const tty = @import("tty.zig");
const pmm = @import("pmm.zig");

const page_size = std.mem.page_size;

pub const Flags = enum(u64) {
    present = 1 << 0,
    write = 1 << 1,
    user = 1 << 2,
    // large = 1 << 7,
    // global = 1 << 8,
    noexec = 1 << 63,
};

pub fn init() !void {
    const kernel_address = root.kernel_address_request.response.?;
    _ = kernel_address;
}
