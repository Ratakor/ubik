const std = @import("std");
const limine = @import("limine");
const root = @import("root");
const tty = @import("tty.zig");

pub fn init() !void {
    const kernel_address = root.kernel_address_request.response.?;
    _ = kernel_address;
}
