const arch = @import("arch.zig");
const Thread = @import("sched.zig").Thread;
const SpinLock = @import("root").SpinLock;

// TODO: this is really ugly, also need threads to work
// TODO: using i as variable is ugly, use slices

pub const max_events = 32;
pub const max_listeners = 32;

pub const Listener = struct {
    thread: *Thread,
    which: usize,
};

pub const Event = struct {
    lock: SpinLock = .{},
    pending: usize = 0,
    listeners_i: usize = 0,
    listeners: [max_listeners]Listener,
};

pub fn init() void {
    // TODO: init events handler like isr
}

pub fn awaitEvent(events: []*Event, block: bool) isize {
    // const thread = sched.currentThread;

    // const old_ints = arch.toggleInterrupts(false);
    // defer _ = arch.toggleInterrupts(old_ints);
    lockEvents(events);
    defer unlockEvents(events);

    var i = checkForPending(events);
    if (i != -1) return i;
    if (!block) return -1;

    attachListeners(events);
    // thread.dequeue();
    unlockEvents(events);
    // sched.yield(true);

    // _ = arch.toggleInterrupts(false);

    // const ret = if (thread.enqueued_by_signal) -1 else thread.which_event;

    lockEvents(events);
    // detachListeners(thread);

    // return ret;
}

pub fn trigger(event: Event, drop: bool) usize {
    const old_state = arch.toggleInterrupts(false);
    defer _ = arch.toggleInterrupts(old_state);

    event.lock.lock();
    defer event.lock.unlock();

    if (event.listeners_i == 0) {
        if (!drop) {
            event.pending += 1;
        }
        return 0;
    }

    for (0..event.listeners_i) |i| {
        const listener = &event.listeners[i];
        const thread = listener.thread;

        thread.which_event = listener.which;
        // sched.enqueueThread(thread, false);
    }

    const ret = event.listeners_i;
    event.listeners_i = 0;
    return ret;
}

fn checkForPending(events: []*Event) isize {
    for (events, 0..) |*event, i| {
        if (event.pending > 0) {
            event.pending -= 1;
            return i;
        }
    }
    return -1;
}

fn attachListeners(events: []*Event, thread: *Thread) void {
    thread.attached_events_i = 0;

    for (events, 0..) |*event, i| {
        if (event.listeners_i == max_listeners) {
            @panic("Event listeners exhausted");
        }

        const listener = event.listeners[event.listeners_i];
        event.listeners_i += 1;
        listener.thread = thread;
        listener.which = i;

        if (thread.attached_events_i == max_events) {
            @panic("Listening on too many events");
        }

        thread.attached_events[thread.attached_events_i] = event;
        thread.attached_events_i += 1;
    }
}

fn detachListeners(thread: *Thread) void {
    for (0..thread.attached_events_i) |i| {
        const event = thread.attached_events[i];

        for (0..event.listeners_i) |j| {
            const listener = &event.listeners[j];
            if (listener.thread != thread) continue;

            event.listeners_i -= 1;
            event.listeners[j] = event.listeners[event.listeners_i];
            break;
        }
    }
    thread.attached_events_i = 0;
}

fn lockEvents(events: []*Event) void {
    for (events) |event| {
        event.lock.lock();
    }
}

fn unlockEvents(events: []*Event) void {
    for (events) |event| {
        event.lock.unlock();
    }
}
