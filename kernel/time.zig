const std = @import("std");
const root = @import("root");
const arch = @import("arch.zig");
const smp = @import("smp.zig");
const pit = arch.pit;
const idt = arch.idt;
const apic = arch.apic;
const ev = @import("event.zig");
const SpinLock = root.SpinLock;
const timespec = root.os.system.timespec;

// TODO: improve, bad_idx is of course ugly
pub const Timer = struct {
    idx: usize,
    done: bool,
    when: timespec,
    event: ev.Event,

    const bad_idx = std.math.maxInt(usize);

    pub fn init(when: timespec) !*Timer {
        var timer = try root.allocator.create(Timer);
        errdefer root.allocator.destroy(timer);

        timer.* = .{
            .idx = bad_idx,
            .when = when,
            .done = false,
            .event = .{},
        };

        try timer.arm();

        return timer;
    }

    pub fn deinit(self: *Timer) void {
        self.disarm();
        root.allocator.destroy(self);
    }

    fn arm(self: *Timer) !void {
        timers_lock.lock();
        defer timers_lock.unlock();

        self.idx = armed_timers.items.len;
        self.done = false;
        try armed_timers.append(root.allocator, self);
    }

    fn disarm(self: *Timer) void {
        timers_lock.lock();
        defer timers_lock.unlock();

        if (self.idx < armed_timers.items.len) {
            _ = armed_timers.swapRemove(self.idx);
            armed_timers.items[self.idx].idx = self.idx;
            self.idx = bad_idx;
        }
    }
};

pub var monotonic: timespec = .{};
pub var realtime: timespec = .{};

var timers_lock: SpinLock = .{};
var armed_timers: std.ArrayListUnmanaged(*Timer) = .{};

pub fn init() void {
    const boot_time = root.boot_time_request.response.?.boot_time;
    realtime.sec = boot_time;

    pit.init();
    const timer_vector = idt.allocVector();
    idt.registerHandler(timer_vector, timerHandler);
    apic.setIRQRedirect(smp.bsp_lapic_id, timer_vector, 0, true);
}

fn timerHandler(ctx: *arch.Context) callconv(.SysV) void {
    _ = ctx;

    defer apic.eoi();

    const interval: timespec = .{ .nsec = std.time.ns_per_s / pit.timer_freq };
    monotonic.add(interval);
    realtime.add(interval);

    if (timers_lock.tryLock()) {
        for (armed_timers.items) |timer| {
            if (timer.done) continue;

            timer.when.sub(interval);
            if (timer.when.sec == 0 and timer.when.nsec == 0) {
                timer.event.trigger(false);
                timer.done = true;
            }
        }

        timers_lock.unlock();
    }
}

pub fn nanosleep(ns: u64) void {
    const duration: timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    const timer = Timer.init(duration) catch return;
    defer timer.deinit();

    var events = [_]*ev.Event{&timer.event};
    _ = ev.awaitEvents(events[0..], true);
}
