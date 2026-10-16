const std = @import("std");
const root = @import("root");
const arch = @import("arch.zig");
const sched = @import("sched.zig");
const SpinLock = root.SpinLock;

pub const Listener = struct {
    thread: *sched.Thread,
    which: usize,
};

const max_events = 32;

pub const Event = struct {
    lock: SpinLock = .{},
    pending: usize = 0,
    listeners: [max_events]Listener = undefined,
    listener_count: usize = 0,

    pub fn trigger(self: *Event, drop: bool) void {
        const old_state = arch.toggleInterrupts(false);
        defer _ = arch.toggleInterrupts(old_state);
        self.lock.lock();
        defer self.lock.unlock();

        var delivered = false;
        for (self.listeners[0..self.listener_count]) |listener| {
            if (sched.wakeEventWait(listener.thread, listener.which)) delivered = true;
        }
        self.listener_count = 0;
        // Listeners already awakened by another event do not consume this one.
        if (!delivered and !drop) self.pending += 1;
    }
};

pub var int_events = [_]Event{.{}} ** 256;

pub fn init() void {
    for (32..0xef) |vec| {
        arch.idt.registerHandler(@intCast(vec), intEventHandler);
    }
}

pub fn awaitEvents(events: []*Event, blocking: bool) ?union { ev: *Event, i: usize } {
    // Keep the caller's order for result indices, but always acquire event locks
    // in address order. Reject duplicates before attempting any lock acquisition.
    if (events.len == 0 or events.len > max_events) @panic("invalid event wait set size");
    var storage: [max_events]*Event = undefined;
    const ordered = storage[0..events.len];
    @memcpy(ordered, events);
    std.mem.sort(*Event, ordered, {}, eventLessThan);
    for (ordered[1..], ordered[0 .. ordered.len - 1]) |event, previous| {
        if (event == previous) @panic("duplicate event in wait set");
    }

    const old_state = arch.toggleInterrupts(false);
    defer _ = arch.toggleInterrupts(old_state);
    lockEvents(ordered);

    if (getFirstPending(events)) |event| {
        unlockEvents(ordered);
        return .{ .ev = event };
    }
    if (!blocking) {
        unlockEvents(ordered);
        return null;
    }

    // Validate all capacities before publishing even the first listener.
    for (events) |event| {
        if (event.listener_count == max_events) @panic("too many event listeners");
    }
    const thread = sched.currentThread();
    for (events, 0..) |event, i| {
        event.listeners[event.listener_count] = .{ .thread = thread, .which = i };
        event.listener_count += 1;
    }
    sched.beginEventWait(thread);
    unlockEvents(ordered);
    // A trigger may win here. yieldAwait must not dequeue the thread again.
    sched.yieldAwait();

    lockEvents(ordered);
    defer unlockEvents(ordered);
    const which = sched.eventWaitResult(thread);
    for (events) |event| {
        for (event.listeners[0..event.listener_count], 0..) |listener, i| {
            if (listener.thread == thread) {
                event.listener_count -= 1;
                event.listeners[i] = event.listeners[event.listener_count];
                break;
            }
        }
    }
    return .{ .i = which };
}

fn intEventHandler(ctx: *arch.Context) callconv(.{ .x86_64_sysv = .{} }) void {
    int_events[ctx.vector].trigger(false);
    arch.apic.eoi();
}

fn getFirstPending(events: []*Event) ?*Event {
    for (events) |event| {
        if (event.pending > 0) {
            event.pending -= 1;
            return event;
        }
    }
    return null;
}

fn eventLessThan(_: void, a: *Event, b: *Event) bool {
    return @intFromPtr(a) < @intFromPtr(b);
}

fn lockEvents(events: []*Event) void {
    for (events) |event| event.lock.lock();
}

fn unlockEvents(events: []*Event) void {
    var i = events.len;
    while (i > 0) {
        i -= 1;
        events[i].lock.unlock();
    }
}
