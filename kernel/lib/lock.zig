const atomic = @import("std").atomic;
const root = @import("root");
const arch = root.arch;

/// Test and test-and-set spinlock
pub const SpinLock = struct {
    state: State = State.init(.unlocked),
    interrupt_state: bool = false,

    const State = atomic.Value(enum(u32) { unlocked, locked });

    /// return true on success
    pub inline fn tryLock(self: *SpinLock) bool {
        const old_state = arch.toggleInterrupts(false);
        if (self.isUnlocked() and self.cmpxchg("Strong")) {
            self.interrupt_state = old_state;
            return true;
        }
        _ = arch.toggleInterrupts(old_state);
        return false;
    }

    pub fn lock(self: *SpinLock) void {
        const old_state = arch.toggleInterrupts(false);
        while (!self.tryLock()) {
            // A TLB sender may hold a lock this CPU needs with IRQs masked.
            root.vmm.serviceShootdown();
            atomic.spinLoopHint();
        }
        self.interrupt_state = old_state;
    }

    pub inline fn unlock(self: *SpinLock) void {
        const old_state = self.interrupt_state;
        self.state.store(.unlocked, .release);
        _ = arch.toggleInterrupts(old_state);
    }

    inline fn isUnlocked(self: *SpinLock) bool {
        return self.state.load(.monotonic) == .unlocked;
    }

    inline fn cmpxchg(self: *SpinLock, comptime strength: []const u8) bool {
        const casFn = @field(@TypeOf(self.state), "cmpxchg" ++ strength);
        return casFn(&self.state, .unlocked, .locked, .acquire, .monotonic) == null;
    }
};
