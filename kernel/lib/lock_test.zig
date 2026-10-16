//! Host-only spinlock tests with interrupt and shootdown mocks.
const std = @import("std");
const SpinLock = @import("lock").SpinLock;

pub const arch = struct {
    var interrupts = true;

    pub fn toggleInterrupts(enabled: bool) bool {
        const previous = interrupts;
        interrupts = enabled;
        return previous;
    }
};

pub const vmm = struct {
    var waiting_on: ?*SpinLock = null;
    var polls: usize = 0;
    var polled_with_irqs_masked = false;

    pub fn serviceShootdown() void {
        polls += 1;
        polled_with_irqs_masked = !arch.interrupts;
        // Model a remote owner completing the operation awaited by this CPU.
        const held = waiting_on orelse @panic("unexpected lock contention");
        waiting_on = null;
        held.unlock();
    }
};

fn reset(enabled: bool) void {
    arch.interrupts = enabled;
    vmm.waiting_on = null;
    vmm.polls = 0;
    vmm.polled_with_irqs_masked = false;
}

test "nested locks preserve the outer interrupt state" {
    for ([_]bool{ true, false }) |enabled| {
        reset(enabled);
        var outer: SpinLock = .{};
        var inner: SpinLock = .{};
        outer.lock();
        try std.testing.expect(!arch.interrupts);
        try std.testing.expect(inner.tryLock());
        try std.testing.expect(!arch.interrupts);
        inner.unlock();
        try std.testing.expect(!arch.interrupts);
        outer.unlock();
        try std.testing.expectEqual(enabled, arch.interrupts);
    }
}

test "failed tryLock preserves caller IRQs and owner saved state" {
    for ([_]bool{ true, false }) |owner_enabled| {
        for ([_]bool{ true, false }) |caller_enabled| {
            reset(owner_enabled);
            var lock: SpinLock = .{};
            try std.testing.expect(lock.tryLock());
            arch.interrupts = caller_enabled;
            try std.testing.expect(!lock.tryLock());
            try std.testing.expectEqual(caller_enabled, arch.interrupts);
            try std.testing.expectEqual(owner_enabled, lock.interrupt_state);
            lock.unlock();
            try std.testing.expectEqual(owner_enabled, arch.interrupts);
            try std.testing.expect(lock.tryLock());
            lock.unlock();
        }
    }
}

test "contended lock polls shootdowns with IRQs masked" {
    for ([_]bool{ true, false }) |enabled| {
        reset(false);
        var lock: SpinLock = .{};
        lock.lock();
        vmm.waiting_on = &lock;
        arch.interrupts = enabled;
        lock.lock();
        try std.testing.expectEqual(@as(usize, 1), vmm.polls);
        try std.testing.expect(vmm.polled_with_irqs_masked);
        try std.testing.expect(!arch.interrupts);
        try std.testing.expect(!lock.tryLock());
        lock.unlock();
        try std.testing.expectEqual(enabled, arch.interrupts);
    }
}
