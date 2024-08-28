const atomic = @import("std").atomic;

/// Test and test-and-set spinlock
pub const SpinLock = struct {
    state: State = State.init(.unlocked),

    const State = atomic.Value(enum(u32) { unlocked, locked });

    /// return true on success
    pub inline fn tryLock(self: *SpinLock) bool {
        return if (self.isUnlocked()) self.cmpxchg("Strong") else false;
    }

    pub fn lock(self: *SpinLock) void {
        while (!self.cmpxchg("Weak")) {
            while (!self.isUnlocked()) {
                atomic.spinLoopHint();
            }
        }
    }

    pub inline fn unlock(self: *SpinLock) void {
        self.state.store(.unlocked, .release);
    }

    inline fn isUnlocked(self: *SpinLock) bool {
        return self.state.load(.monotonic) == .unlocked;
    }

    inline fn cmpxchg(self: *SpinLock, comptime strength: []const u8) bool {
        const casFn = @field(@TypeOf(self.state), "cmpxchg" ++ strength);
        return casFn(&self.state, .unlocked, .locked, .acquire, .monotonic) == null;
    }
};
