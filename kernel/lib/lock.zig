const atomic = @import("std").atomic;

/// Test and test-and-set spinlock
pub const SpinLock = struct {
    state: State = State.init(.unlocked),

    const State = atomic.Atomic(enum(u32) { unlocked, locked });

    /// return true on success
    pub inline fn tryLock(self: *SpinLock) bool {
        return if (self.isUnlocked()) self.lockImpl("compareAndSwap") else false;
    }

    pub fn lock(self: *SpinLock) void {
        while (!self.lockImpl("tryCompareAndSwap")) {
            while (!self.isUnlocked()) {
                atomic.spinLoopHint();
            }
        }
    }

    pub inline fn unlock(self: *SpinLock) void {
        self.state.store(.unlocked, .Release);
    }

    inline fn isUnlocked(self: *SpinLock) bool {
        return self.state.load(.Monotonic) == .unlocked;
    }

    inline fn lockImpl(self: *SpinLock, comptime cas_fn_name: []const u8) bool {
        const casFn = @field(@TypeOf(self.state), cas_fn_name);
        return casFn(&self.state, .unlocked, .locked, .Acquire, .Monotonic) == null;
    }
};
