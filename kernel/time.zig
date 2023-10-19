//! https://wiki.osdev.org/PIT

const std = @import("std");
const root = @import("root");
const arch = @import("arch.zig");
const smp = @import("smp.zig");
const idt = arch.idt;
const apic = @import("apic.zig");
const SpinLock = @import("SpinLock.zig");
const log = std.log.scoped(.pit);

pub const timespec = extern struct {
    tv_sec: isize = 0,
    tv_nsec: isize = 0,

    pub inline fn add(self: *timespec, ts: timespec) void {
        if (self.tv_nsec + ts.tv_nsec > max_ns) {
            self.tv_nsec = (self.tv_nsec + ts.tv_nsec) - ns_per_s;
            self.tv_sec += 1;
        } else {
            self.tv_nsec += ts.tv_nsec;
        }
        self.tv_sec += ts.tv_sec;
    }

    pub inline fn sub(self: *timespec, ts: timespec) void {
        if (ts.tv_nsec > self.tv_nsec) {
            self.tv_nsec = max_ns - (ts.tv_nsec - self.tv_nsec);
            if (self.tv_sec == 0) {
                self.tv_nsec = 0;
                return;
            }
            self.tv_sec -= 1;
        } else {
            self.tv_nsec -= ts.tv_nsec;
        }

        if (ts.tv_sec > self.tv_sec) {
            self.tv_sec = 0;
            self.tv_nsec = 0;
        } else {
            self.tv_sec -= ts.tv_sec;
        }
    }
};

pub const Timer = struct {
    idx: usize,
    done: bool,
    when: timespec,
    // event: ev.Event;

    pub fn init(when: timespec) !*Timer {
        var timer = try root.allocator.create(Timer);
        timer.idx = bad_idx;
        timer.when = when;
        timer.done = false;
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
        armed_timers.append(self) catch |err| return err;
    }

    fn disarm(self: *Timer) void {
        timers_lock.lock();
        defer timers_lock.unlock();

        if (armed_timers.items.len == 0 or self.idx == bad_idx or self.idx >= armed_timers.items.len) {
            return;
        }

        armed_timers.items[self.idx] = armed_timers.getLast();
        armed_timers.items[self.idx].idx = self.idx;
        _ = armed_timers.pop();
        self.idx = bad_idx;
    }
};

const bad_idx = std.math.maxInt(usize);
pub const dividend = 1_193_182;
pub const timer_freq = 100;
pub const ns_per_s = std.time.ns_per_s;
pub const max_ns = ns_per_s - 1;

pub var monotonic: timespec = .{};
pub var realtime: timespec = .{};

var timers_lock: SpinLock = .{};
var armed_timers = std.ArrayList(*Timer).init(root.allocator); // TODO

pub fn init() void {
    const boot_time = root.boot_time_request.response.?.boot_time;
    realtime.tv_sec = boot_time;

    setFrequency(timer_freq);
    const timer_vector = idt.allocVector();
    idt.registerHandler(timer_vector, timerHandler);
    apic.setIRQRedirect(smp.bsp_lapic_id, timer_vector, 0);

    log.info("realtime: {}", .{realtime});
}

fn setFrequency(divisor: u64) void {
    var count: u16 = @truncate(dividend / divisor);
    if (dividend % divisor > divisor / 2) {
        count += 1;
    }
    setReloadValue(count);
}

pub fn setReloadValue(count: u16) void {
    // channel 0, lo/hi access mode, mode 2 (rate generator)
    arch.out(u8, 0x43, 0b00_11_010_0);
    arch.out(u8, 0x40, @truncate(count));
    arch.out(u8, 0x40, @truncate(count >> 8));
}

pub fn getCurrentCount() u16 {
    arch.out(u8, 0x43, 0);
    const lo = arch.in(u8, 0x40);
    const hi = arch.in(u8, 0x40);
    return (@as(u16, hi) << 8) | lo;
}

fn timerHandler(ctx: *arch.Context) void {
    _ = ctx;

    defer apic.eoi();

    const interval: timespec = .{ .tv_nsec = ns_per_s / timer_freq };
    monotonic.add(interval);
    realtime.add(interval);

    if (timers_lock.tryLock()) {
        for (armed_timers.items) |timer| {
            if (timer.done) continue;

            timer.when.sub(interval);
            if (timer.when.tv_sec == 0 and timer.when.tv_nsec == 0) {
                // ev.trigger(&timer.event, false);
                timer.done = true;
            }
        }
        timers_lock.unlock();
    }
}

pub fn nanosleep(ns: u64) void {
    const duration: timespec = .{
        .tv_sec = @intCast(ns / ns_per_s),
        .tv_nsec = @intCast(ns % ns_per_s),
    };
    const timer = Timer.init(duration) catch return;
    defer timer.deinit();
    // const events: []*ev.Event = .{ &timer.event };
    // ev.await(events, true);

    // TODO
    while (!timer.done) asm volatile ("hlt");
}
