const atomic = @import("std").atomic;

// pub const State = atomic.Atomic(enum(i64) {
//     unlocked,
//     locked,
//     waiting,
// });

pub const State = enum(i64) {
    unlocked,
    locked,
    waiting,
};

pub const SpinLock = struct {
    state: State = State.init(.locked),

    const Self = @This();

    /// return true on success
    pub inline fn tryLock(self: *Self) bool {
        // return self.state.compareAndSwap(.unlocked, .locked, .Acquire, .Monotonic) == null;
        return @cmpxchgStrong(State, &self.state, .unlocked, .locked, .Acquire, .Monotonic) == null;
    }

    pub inline fn lock(self: *Self) void {
        switch (@atomicRmw(State, &self.state, .Xchg, .locked, .Acquire)) {
            .unlocked => {},
            else => |state| self.spinLock(state),
        }
    }

    pub inline fn unlock(self: *Self) void {
        switch (@atomicRmw(State, &self.state, .Xchg, .unlocked, .Release)) {
            .unlocked, .waiting => unreachable, // panic on double unlock
            .locked => {},
        }
    }

    // TODO: this is too complicated
    noinline fn spinLock(self: *Self, curr_state: State) void {
        var new_state = curr_state;

        for (0..100) |spin| {
            const state = @cmpxchgWeak(State, &self.state, .unlocked, new_state, .Acquire, .Monotonic) orelse return;
            switch (state) {
                .unlocked, .locked => {},
                .waiting => break,
            }

            for (0..@min(32, spin)) |_| {
                atomic.spinLoopHint();
            }
        }

        new_state = .waiting;

        while (true) {
            switch (@atomicRmw(State, &self.state, .Xchg, new_state, .Acquire)) {
                .unlocked => return,
                else => {},
            }

            atomic.spinLoopHint();
        }
    }
};

// noinline fn acquire(self: *SpinLock) void {
//     var deadlock_counter: usize = 0;

//     while (true) {
//         if (self.tryLock()) {
//             break;
//         }

//         if (deadlock_counter >= 100) {
//             @panic("deadlock");
//         }
//         deadlock_counter += 1;

//         atomic.spinLoopHint();
//     }
// }
