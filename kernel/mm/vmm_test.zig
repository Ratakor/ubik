//! Host-only harness; no kernel initialization or privileged instructions.
//! Run from the repository root (validated with dev1827, not pinned dev1637):
//! zig test --test-runner kernel/test_runner.zig --dep harness=root --dep ubik --dep lock -Mroot=kernel/mm/vmm_test.zig -Mubik=lib/ubik.zig -Mlock=kernel/lib/lock.zig
//! The runner re-exports this module so kernel @import("root") sees the mocks.
const std = @import("std");
const ubik = @import("ubik");
pub const vmm = @import("vmm.zig");
pub const SpinLock = @import("lock").SpinLock;
pub var allocator = std.testing.allocator;
const page = std.mem.page_size;
const base = 0x400000;
const rw = ubik.PROT.READ | ubik.PROT.WRITE;
const private: ubik.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
const shared: ubik.MAP = .{ .TYPE = .SHARED, .ANONYMOUS = true };

// A custom runner makes the mocks visible to kernel @import("root") calls.
pub fn main() !void {
    for (@import("builtin").test_functions) |case| {
        std.testing.allocator_instance = .{};
        defer if (std.testing.allocator_instance.deinit() == .leak) @panic("test allocator leak");
        std.debug.print("{s}... ", .{case.name});
        try case.func();
        std.debug.print("OK\n", .{});
    }
}

pub const arch = struct {
    var interrupts = true;
    var cr3: u64 = 0;
    var invalidations: usize = 0;
    pub const Context = struct {};
    pub const idt = struct {};
    pub const apic = struct {
        pub const lapic_base = 0;
        pub fn sendIPI(_: u32, _: struct { vector: u8 }) void {
            @panic("host test must not send IPIs");
        }
    };
    pub fn toggleInterrupts(enabled: bool) bool {
        const old = interrupts;
        interrupts = enabled;
        return old;
    }
    pub fn readRegister(comptime name: []const u8) u64 {
        std.debug.assert(std.mem.eql(u8, name, "cr3"));
        return cr3;
    }
    pub fn writeRegister(comptime name: []const u8, value: u64) void {
        std.debug.assert(std.mem.eql(u8, name, "cr3"));
        cr3 = value;
    }
    pub fn invlpg(_: u64) void {
        invalidations += 1;
    }
};

pub const smp = struct {
    pub var initialized = false;
    const Cpu = struct { tlb_shootdown_cr3: u64 = 0, lapic_id: u32 = 0 };
    var cpu_storage: [1]Cpu = .{.{}};
    pub var cpus: []Cpu = &cpu_storage;
    pub fn thisCpu() *Cpu {
        return &cpus[0];
    }
};

pub const sched = struct {
    const Process = struct { addr_space: *vmm.AddressSpace };
    const Thread = struct { process: *Process };
    var process: Process = undefined;
    var thread: Thread = .{ .process = &process };
    pub fn currentThread() *Thread {
        return &thread;
    }
};

pub const pmm = struct {
    // Static aligned storage keeps physical addresses dereferenceable at HHDM 0.
    var storage: [256][page]u8 align(page) = undefined;
    var used: [256]bool = [_]bool{false} ** 256;
    var live: usize = 0;
    var budget: ?usize = null;

    pub fn alloc(pages: usize, comptime zero: bool) ?u64 {
        if (budget) |remaining| {
            if (remaining == 0) return null;
            budget = remaining - 1;
        }
        var run: usize = 0;
        for (used, 0..) |busy, i| {
            run = if (busy) 0 else run + 1;
            if (run != pages) continue;
            const start = i + 1 - pages;
            @memset(used[start .. i + 1], true);
            live += pages;
            const address = @intFromPtr(&storage[start]);
            if (zero) @memset(@as([*]u8, @ptrFromInt(address))[0 .. pages * page], 0);
            return address;
        }
        return null;
    }
    pub fn free(address: u64, pages: usize) void {
        const start = (address - @intFromPtr(&storage)) / page;
        std.debug.assert(address % page == 0);
        for (used[start .. start + pages]) |*busy| {
            std.debug.assert(busy.*);
            busy.* = false;
        }
        live -= pages;
    }
    fn owns(address: u64) bool {
        return used[(address - @intFromPtr(&storage)) / page];
    }
};

var kernel: vmm.AddressSpace = undefined;
fn setup() void {
    std.debug.assert(pmm.live == 0);
    allocator = std.testing.allocator;
    pmm.budget = null;
    arch.interrupts = true;
    arch.cr3 = 0;
    arch.invalidations = 0;
    smp.initialized = false;
    smp.cpu_storage = .{.{}};
    smp.cpus = &smp.cpu_storage;
    vmm.hhdm_offset = 0;
    kernel = .{ .pml4 = @ptrFromInt(pmm.alloc(1, true).?) };
    vmm.kaddr_space = &kernel;
}
fn teardown() void {
    pmm.budget = null;
    pmm.free(@intFromPtr(kernel.pml4), 1);
    std.testing.expectEqual(@as(usize, 0), pmm.live) catch @panic("physical page leak");
    std.testing.expect(arch.interrupts) catch @panic("IRQ state leaked");
}
fn mapping(space: *vmm.AddressSpace, address: u64, count: usize, prot: i32, flags: ubik.MAP) !u64 {
    const physical = pmm.alloc(count, true) orelse return error.OutOfMemory;
    errdefer pmm.free(physical, count);
    try space.mmapRange(address, physical, count * page, prot, flags);
    return physical;
}
fn fault(space: *vmm.AddressSpace, address: u64, reason: u32) !void {
    sched.process = .{ .addr_space = space };
    try vmm.handlePageFault(address, @bitCast(reason));
}
fn bytes(physical: u64) *[page]u8 {
    return @ptrFromInt(physical);
}
fn unlocked(space: *vmm.AddressSpace) !void {
    try std.testing.expect(space.lock.tryLock());
    space.lock.unlock();
    try std.testing.expect(arch.interrupts);
}

test "sparse page tables deinit and fork skip absent branches and leaves" {
    setup();
    defer teardown();
    const parent = try vmm.AddressSpace.init();
    defer parent.deinit();
    const addresses = [_]u64{ base, base + (1 << 21), base + (1 << 30), base + (1 << 39) };
    for (addresses) |address| {
        const physical = try mapping(parent, address, 3, rw, private);
        const local = parent.mmap_ranges.items[parent.mmap_ranges.items.len - 1];
        try parent.unmapPage(address + page, true);
        try local.global.shadow_addr_space.unmapPage(address + page, true);
        pmm.free(physical + page, 1);
        try parent.unmapPage(address + 2 * page, true);
    }
    const child = try parent.fork();
    defer child.deinit();
    for (addresses) |address| {
        const original = try parent.virt2phys(address);
        const copy = try child.virt2phys(address);
        try std.testing.expect(original != copy);
        try std.testing.expectEqualSlices(u8, bytes(original), bytes(copy));
        try std.testing.expectError(error.NotMapped, child.virt2phys(address + page));
        try fault(child, address + page + 17, 0);
        try std.testing.expectEqual(@as(u8, 0), bytes(try child.virt2phys(address + page))[17]);
        // Private ownership resides in the shadow even for a missing local PTE.
        try std.testing.expect(pmm.owns(try child.virt2phys(address + 2 * page)));
    }
}

test "private fork isolates ownership through unmap and offset refault" {
    setup();
    defer teardown();
    const parent = try vmm.AddressSpace.init();
    defer parent.deinit();
    const original = try mapping(parent, base, 1, rw, private);
    bytes(original)[37] = 0xa5;
    const child = try parent.fork();
    defer child.deinit();
    const copy = try child.virt2phys(base);
    try std.testing.expect(copy != original);
    try std.testing.expectEqual(@as(u8, 0xa5), bytes(copy)[37]);
    bytes(copy)[37] = 0x5a;
    try parent.munmap(base, page);
    try std.testing.expect(!pmm.owns(original));
    try std.testing.expect(pmm.owns(copy));
    try child.unmapPage(base, true);
    try fault(child, base + 37, 0);
    try std.testing.expectEqual(copy, try child.virt2phys(base));
    try std.testing.expectEqual(@as(u8, 0x5a), bytes(copy)[37]);
    try unlocked(child);
    try fault(child, base + 123, 0); // Already-resolved fault must also unlock.
    try unlocked(child);
    try child.munmap(base, page);
    try std.testing.expect(!pmm.owns(copy));
}

test "munmap crosses adjacent ranges and holes" {
    setup();
    defer teardown();
    const space = try vmm.AddressSpace.init();
    defer space.deinit();
    _ = try mapping(space, base, 1, rw, private);
    _ = try mapping(space, base + page, 1, rw, private);
    _ = try mapping(space, base + 3 * page, 1, rw, private);
    try space.munmap(base, 4 * page);
    try std.testing.expectEqual(@as(usize, 0), space.mmap_ranges.items.len);
    for (0..4) |i| try std.testing.expectError(error.NotMapped, space.virt2phys(base + i * page));
}

test "interior split retains shared aliases then reclaims final owners" {
    setup();
    defer teardown();
    const parent = try vmm.AddressSpace.init();
    defer parent.deinit();
    const physical = try mapping(parent, base, 3, rw, shared);
    const child = try parent.fork();
    defer child.deinit();
    try parent.munmap(base + page, page);
    try std.testing.expectEqual(@as(usize, 2), parent.mmap_ranges.items.len);
    try std.testing.expect(pmm.owns(physical + page));
    try std.testing.expectEqual(physical + 2 * page, try parent.virt2phys(base + 2 * page));
    try child.munmap(base + page, page);
    try std.testing.expect(!pmm.owns(physical + page));
    try parent.munmap(base, 3 * page);
    try std.testing.expect(pmm.owns(physical));
    try std.testing.expect(pmm.owns(physical + 2 * page));
    try child.munmap(base, 3 * page);
    try std.testing.expect(!pmm.owns(physical));
    try std.testing.expect(!pmm.owns(physical + 2 * page));
}

test "partial unmap fork copies retained tails with correct offsets" {
    setup();
    defer teardown();
    const parent = try vmm.AddressSpace.init();
    defer parent.deinit();
    const physical = try mapping(parent, base, 4, rw, private);
    bytes(physical + 3 * page)[19] = 0x73;
    try parent.munmap(base, page);
    try parent.munmap(base + 2 * page, page);
    const child = try parent.fork();
    defer child.deinit();
    try std.testing.expectError(error.NotMapped, child.virt2phys(base));
    try std.testing.expectError(error.NotMapped, child.virt2phys(base + 2 * page));
    const tail = try child.virt2phys(base + 3 * page);
    try std.testing.expect(tail != physical + 3 * page);
    try std.testing.expectEqual(@as(u8, 0x73), bytes(tail)[19]);
    try child.unmapPage(base + 3 * page, true);
    try fault(child, base + 3 * page + 19, 0);
    try std.testing.expectEqual(tail, try child.virt2phys(base + 3 * page));
}

test "mmap rejects range and raw PTE overlaps without taking ownership" {
    setup();
    defer teardown();
    const space = try vmm.AddressSpace.init();
    defer space.deinit();
    const existing = try mapping(space, base + page, 1, rw, private);
    const incoming = pmm.alloc(2, true).?;
    defer pmm.free(incoming, 2);
    const before = pmm.live;
    try std.testing.expectError(error.AlreadyMapped, space.mmapRange(base, incoming, 2 * page, rw, private));
    try std.testing.expectEqual(before, pmm.live);
    try std.testing.expectEqual(existing, try space.virt2phys(base + page));
    try std.testing.expectError(error.NotMapped, space.virt2phys(base));
    try space.mapPage(base + 4 * page, incoming, 1);
    defer space.unmapPage(base + 4 * page, true) catch unreachable;
    try std.testing.expectError(error.AlreadyMapped, space.mmapRange(base + 3 * page, incoming, 2 * page, rw, private));
    try std.testing.expectError(error.NotMapped, space.virt2phys(base + 3 * page));
    try std.testing.expectEqual(@as(usize, 1), space.mmap_ranges.items.len);
}

test "PROT_NONE retains backing ownership across fork and unmap" {
    setup();
    defer teardown();
    const parent = try vmm.AddressSpace.init();
    defer parent.deinit();
    const physical = try mapping(parent, base, 1, ubik.PROT.NONE, private);
    try std.testing.expectError(error.NotMapped, parent.virt2phys(base));
    try std.testing.expectError(error.PageProtectionViolation, fault(parent, base + 7, 0));
    const child = try parent.fork();
    defer child.deinit();
    const copy = (try child.virt2pte(base, false)).getAddress();
    try std.testing.expect(copy != physical);
    try std.testing.expect(pmm.owns(copy));
    try std.testing.expectError(error.NotMapped, child.virt2phys(base));
    try parent.munmap(base, page);
    try std.testing.expect(!pmm.owns(physical));
    try std.testing.expect(pmm.owns(copy));
    try child.munmap(base, page);
    try std.testing.expect(!pmm.owns(copy));
}

test "permissions reject disallowed faults and preserve IRQ and lock state" {
    setup();
    defer teardown();
    const space = try vmm.AddressSpace.init();
    defer space.deinit();
    const protections = [_]i32{ ubik.PROT.READ, rw, ubik.PROT.EXEC, ubik.PROT.NONE };
    for (protections, 0..) |prot, i| {
        const address = base + i * page;
        _ = try mapping(space, address, 1, prot, private);
        const pte = try space.virt2pte(address, false);
        try std.testing.expect(pte.user);
        try std.testing.expectEqual(prot != ubik.PROT.NONE, pte.present);
        try std.testing.expectEqual((prot & ubik.PROT.WRITE) != 0, pte.writable);
        try std.testing.expectEqual((prot & ubik.PROT.EXEC) == 0, pte.execute_disable);
        for ([_]u32{ 0, 2, 16 }) |reason| {
            const permitted = if (reason == 2) (prot & ubik.PROT.WRITE) != 0 else if (reason == 16) (prot & ubik.PROT.EXEC) != 0 else (prot & rw) != 0;
            if (permitted) try fault(space, address + 11, reason) else try std.testing.expectError(error.PageProtectionViolation, fault(space, address + 11, reason));
            try unlocked(space);
        }
    }
    for ([_]u32{ 1, 8, 32, 64, 1 << 15 }) |reason| {
        try std.testing.expectError(error.PageProtectionViolation, fault(space, base, reason));
    }
    try std.testing.expectError(error.RangeNotFound, fault(space, base + 8 * page, 0));
    arch.interrupts = false;
    try fault(space, base + 9, 0);
    try std.testing.expect(!arch.interrupts);
    arch.interrupts = true;
    // Another range operation detects a leaked global range lock as well.
    try space.munmap(base, protections.len * page);
}

test "fault OOM releases both locks without losing backing ownership" {
    setup();
    defer teardown();
    const space = try vmm.AddressSpace.init();
    defer space.deinit();
    const physical = try mapping(space, base, 1, rw, private);
    const shadow = space.mmap_ranges.items[0].global.shadow_addr_space;
    try space.unmapPage(base, true);
    try shadow.unmapPage(base, true);
    pmm.free(physical, 1);
    pmm.budget = 0;
    try std.testing.expectError(error.OutOfMemory, fault(space, base + 23, 0));
    pmm.budget = null;
    try unlocked(space);
    try std.testing.expectError(error.NotMapped, space.virt2phys(base));
    try fault(space, base + 23, 0);
    try std.testing.expect(pmm.owns(try space.virt2phys(base)));
    try space.munmap(base, page);
}

test "mapping OOM rolls back translations and leaves pages caller owned" {
    // At a page-table boundary, failures exercise rollback after the first leaf.
    for (0..11) |budget| {
        setup();
        defer teardown();
        const space = try vmm.AddressSpace.init();
        defer space.deinit();
        const physical = pmm.alloc(2, true).?;
        const address = (1 << 21) - page;
        pmm.budget = budget;
        const result = space.mmapRange(address, physical, 2 * page, rw, private);
        pmm.budget = null;
        if (result) |_| {
            try space.munmap(address, 2 * page);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), space.mmap_ranges.items.len);
            try std.testing.expectError(error.NotMapped, space.virt2phys(address));
            try std.testing.expectError(error.NotMapped, space.virt2phys(address + page));
            try std.testing.expect(pmm.owns(physical));
            try std.testing.expect(pmm.owns(physical + page));
            pmm.free(physical, 2);
        }
        try unlocked(space);
    }
}
