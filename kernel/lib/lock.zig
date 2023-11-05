const std = @import("std");
const builtin = @import("builtin");

pub const SpinLock = struct {
    state: State = State.init(unlocked),

    const State = std.atomic.Atomic(u32);
    const unlocked = 0b00;
    const locked = 0b01;
    const contended = 0b11; // TODO: use contended for lockSlow / unlock

    /// return true on success
    pub inline fn tryLock(self: *SpinLock) bool {
        return self.lockFast("compareAndSwap");
    }

    pub inline fn lock(self: *SpinLock) void {
        if (!self.lockFast("tryCompareAndSwap")) {
            self.lockSlow();
        }
    }

    inline fn lockFast(self: *SpinLock, comptime cas_fn_name: []const u8) bool {
        // optimization for x86
        if (comptime builtin.target.cpu.arch.isX86()) {
            const locked_bit = @ctz(@as(u32, locked));
            return self.state.bitSet(locked_bit, .Acquire) == 0;
        }

        const casFn = @field(@TypeOf(self.state), cas_fn_name);
        return casFn(&self.state, unlocked, locked, .Acquire, .Monotonic) == null;
    }

    fn lockSlow(self: *SpinLock) void {
        @setCold(true);

        for (0..100_000_000) |_| {
            if (self.lockFast("tryCompareAndSwap")) {
                return;
            }
            std.atomic.spinLoopHint();
        }

        @panic("Deadlock");
    }

    pub inline fn unlock(self: *SpinLock) void {
        const state = self.state.swap(unlocked, .Release);
        std.debug.assert(state != unlocked);
    }
};
