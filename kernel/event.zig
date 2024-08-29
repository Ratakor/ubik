const std = @import("std");
const root = @import("root");
const arch = @import("arch.zig");
const sched = @import("sched.zig");
const SpinLock = root.SpinLock;

// TODO: this can be simplified

pub const Listener = struct {
    thread: *sched.Thread,
    which: usize,
};

// TODO
// pub const Events = struct {
//     lock: SpinLock,
//     events: std.ArrayListUnmanaged(usize),
//     // events: struct {
//     //     pending: usize,
//     //     listeners: std.ArrayListUnmanaged(Listener),
//     // },
// };

pub const Event = struct {
    lock: SpinLock = .{},
    pending: usize = 0,
    listeners: std.BoundedArray(Listener, 32) = .{},

    pub fn trigger(self: *Event, drop: bool) void {
        const old_state = arch.toggleInterrupts(false);
        defer _ = arch.toggleInterrupts(old_state);

        self.lock.lock();
        defer self.lock.unlock();

        if (self.listeners.len == 0) {
            if (!drop) {
                self.pending += 1;
            }
        } else {
            for (self.listeners.slice()) |listener| {
                const thread = listener.thread;
                thread.which_event = listener.which;
                sched.enqueue(thread) catch unreachable;
            }

            self.listeners.len = 0;
        }
    }
};

pub var int_events = [_]Event{.{}} ** 256;

pub fn init() void {
    for (32..0xef) |vec| {
        arch.idt.registerHandler(@intCast(vec), intEventHandler);
    }
}

pub fn awaitEvents(events: []*Event, blocking: bool) ?union { ev: *Event, i: usize } {
    const old_state = arch.toggleInterrupts(false);
    defer _ = arch.toggleInterrupts(old_state);

    lockEvents(events);
    defer unlockEvents(events);

    if (getFirstPending(events)) |event| {
        return .{ .ev = event };
    }

    if (!blocking) {
        return null;
    }

    const thread = sched.currentThread();
    attachListeners(events, thread);
    sched.dequeue(thread); // re-enqueue when? <- Event.trigger
    unlockEvents(events);
    sched.yieldAwait();

    arch.disableInterrupts();

    // TODO
    // if (thread.enqueued_by_signal) {
    //     return error.
    // }
    const ret = .{ .i = thread.which_event };

    lockEvents(events);
    detachListeners(thread);

    return ret;
}

fn intEventHandler(ctx: *arch.Context) callconv(.SysV) void {
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

fn attachListeners(events: []*Event, thread: *sched.Thread) void {
    thread.attached_events.len = 0;

    for (events, 0..) |event, i| {
        // TODO: replace with append + panic?
        event.listeners.appendAssumeCapacity(.{ .thread = thread, .which = i });
        thread.attached_events.appendAssumeCapacity(event);
    }
}

fn detachListeners(thread: *sched.Thread) void {
    for (thread.attached_events.slice()) |event| {
        for (event.listeners.slice(), 0..) |listener, i| {
            if (listener.thread == thread) {
                _ = event.listeners.swapRemove(i); // TODO: weird (loop)
            }
        }
    }

    thread.attached_events.len = 0;
}

inline fn lockEvents(events: []*Event) void {
    for (events) |event| {
        event.lock.lock();
    }
}

inline fn unlockEvents(events: []*Event) void {
    for (events) |event| {
        event.lock.unlock();
    }
}
