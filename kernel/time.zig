//! https://wiki.osdev.org/PIT
// TODO: move PIT code to arch/x86_64/pit.zig

const std = @import("std");
const root = @import("root");
const arch = @import("arch.zig");
const smp = @import("smp.zig");
const idt = arch.idt;
const apic = arch.apic;
const ev = @import("event.zig");
const SpinLock = root.SpinLock;
const timespec = root.os.system.timespec;

pub const Timer = struct {
    idx: usize,
    done: bool,
    when: timespec,
    event: ev.Event,

    const bad_idx = std.math.maxInt(usize);

    pub fn init(when: timespec) !*Timer {
        var timer = try root.allocator.create(Timer);
        errdefer root.allocator.destroy(timer);

        timer.idx = bad_idx;
        timer.when = when;
        timer.done = false;
        timer.event = try ev.Event.init();
        errdefer timer.event.deinit();

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
        armed_timers.append(root.allocator, self) catch |err| return err;
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

pub const dividend = 1_193_182;
pub const timer_freq = 1000;

pub var monotonic: timespec = .{};
pub var realtime: timespec = .{};

var timers_lock: SpinLock = .{};
var armed_timers: std.ArrayListUnmanaged(*Timer) = .{};

pub fn init() void {
    const boot_time = root.boot_time_request.response.?.boot_time;
    realtime.tv_sec = boot_time;

    setFrequency(timer_freq);
    const timer_vector = idt.allocVector();
    idt.registerHandler(timer_vector, timerHandler);
    apic.setIRQRedirect(smp.bsp_lapic_id, timer_vector, 0);
}

fn setFrequency(divisor: u64) void {
    var count = dividend / divisor;
    if (dividend % divisor > divisor / 2) {
        count += 1;
    }
    setReloadValue(@truncate(count));
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

fn timerHandler(ctx: *arch.Context) callconv(.SysV) void {
    _ = ctx;

    defer apic.eoi();

    const interval: timespec = .{ .tv_nsec = std.time.ns_per_s / timer_freq };
    monotonic.add(interval);
    realtime.add(interval);

    if (timers_lock.tryLock()) {
        for (armed_timers.items) |timer| {
            if (timer.done) continue;

            timer.when.sub(interval);
            if (timer.when.tv_sec == 0 and timer.when.tv_nsec == 0) {
                timer.event.trigger(false);
                timer.done = true;
            }
        }

        timers_lock.unlock();
    }
}

pub fn nanosleep(ns: u64) void {
    const duration: timespec = .{
        .tv_sec = @intCast(ns / std.time.ns_per_s),
        .tv_nsec = @intCast(ns % std.time.ns_per_s),
    };
    const timer = Timer.init(duration) catch return;
    defer timer.deinit();

    var events = [_]*ev.Event{&timer.event};
    _ = ev.awaitEvents(events[0..], true);
}
