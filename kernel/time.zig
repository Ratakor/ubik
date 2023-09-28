const std = @import("std");
const root = @import("root");

pub const Timespec = struct {
    tv_sec: isize = 0,
    tv_nsec: isize = 0,
};

pub var realtime: Timespec = .{};

pub fn init() void {
    const boot_time = root.boot_time_request.response.?;
    realtime.tv_sec = boot_time.boot_time;
}
