//! Intel Manual 3A: https://cdrdv2.intel.com/v1/dl/getContent/671190

const std = @import("std");
const root = @import("root");
const arch = @import("arch.zig");
const idt = arch.idt;
const apic = @import("apic.zig");
const pmm = @import("pmm.zig");
const smp = @import("smp.zig");
const sched = @import("sched.zig");
const SpinLock = @import("SpinLock.zig");
const log = std.log.scoped(.vmm);
const alignBackward = std.mem.alignBackward;
const alignForward = std.mem.alignForward;
const page_size = std.mem.page_size;

// TODO: TLB + mapRange/unmapRange?

pub const MapError = error{
    OutOfMemory,
    AlreadyMapped,
    NotMapped,
};

/// Page Table Entry
pub const PTE = packed struct {
    p: u1, // present
    rw: u1, // read/write
    us: u1, // user/supervisor
    pwt: u1, // write-through
    pcd: u1, // cache disable
    a: u1, // accessed
    d: u1, // dirty
    pat: u1, // page attribute table
    g: u1, // global
    ignored1: u3,
    address: u40, // between u24 and u39 based on MAXPHYADDR from cpuid, the rest must be 0s
    ignored2: u7,
    pk: u4, // protection key
    xd: u1, // execute disable

    const present: u64 = 1 << 0;
    const writable: u64 = 1 << 1;
    const user: u64 = 1 << 2;
    const noexec: u64 = 1 << 63;

    pub inline fn getAddress(self: PTE) u64 {
        return @as(u64, self.address) << 12;
    }

    inline fn getNextLevel(self: *PTE, allocate: bool) ?[*]PTE {
        if (self.p != 0) {
            return @ptrFromInt(self.getAddress() + hhdm_offset);
        }

        if (!allocate) {
            return null;
        }

        const new_page_table = pmm.alloc(1, true) orelse return null;
        // errno = ENOMEM
        self.* = @bitCast(new_page_table | present | writable | user);
        return @ptrFromInt(new_page_table + hhdm_offset);
    }
};

// TODO
const Mapping = struct {
    base: usize,
    length: usize,
    offset: isize,
    prot: i32,
    flags: i32,
};

pub const AddressSpace = struct {
    pml4: *[512]PTE,
    lock: SpinLock = .{},
    mappings: std.ArrayListUnmanaged(Mapping) = .{}, // TODO

    const Self = @This();

    pub fn init() !*Self {
        const addr_space = try root.allocator.create(AddressSpace);
        const pml4_phys = pmm.alloc(1, true) orelse {
            root.allocator.destroy(addr_space);
            return error.OutOfMemory;
        };
        addr_space.pml4 = @ptrFromInt(pml4_phys + hhdm_offset);
        addr_space.lock = .{};

        // TODO
        // for (256..512) |i| {
        //     addr_space.pml4[i] = kaddr_space.pml4[i];
        // }

        return addr_space;
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // TODO
    }

    pub fn fork(self: *Self) !*Self {
        _ = self;
        // TODO
    }

    pub fn virt2pte(self: *const Self, vaddr: u64, allocate: bool) ?*PTE {
        const pml4_idx = (vaddr & (0x1ff << 39)) >> 39;
        const pml3_idx = (vaddr & (0x1ff << 30)) >> 30;
        const pml2_idx = (vaddr & (0x1ff << 21)) >> 21;
        const pml1_idx = (vaddr & (0x1ff << 12)) >> 12;

        const pml4 = self.pml4;
        const pml3 = pml4[pml4_idx].getNextLevel(allocate) orelse return null;
        const pml2 = pml3[pml3_idx].getNextLevel(allocate) orelse return null;
        const pml1 = pml2[pml2_idx].getNextLevel(allocate) orelse return null;

        return &pml1[pml1_idx];
    }

    pub fn virt2phys(self: *const Self, vaddr: u64) MapError!u64 {
        const pte = self.virt2pte(vaddr, false) orelse unreachable;
        if (pte.p == 0) return error.NotMapped;
        return pte.getAddress();
    }

    pub fn mapPage(self: *Self, vaddr: u64, paddr: u64, flags: u64) MapError!void {
        self.lock.lock();
        defer self.lock.unlock();

        // TODO: when virt2pte fails the memory it allocated is not freed
        const pte = self.virt2pte(vaddr, true) orelse return error.OutOfMemory;
        if (pte.p != 0) return error.AlreadyMapped;
        pte.* = @bitCast(paddr | flags);

        if (@intFromPtr(self.pml4) == arch.readRegister("cr3")) {
            // TODO: TLB shootdown
            arch.invlpg(vaddr);
        }
    }

    pub fn remapPage(self: *Self, vaddr: u64, flags: u64) MapError!void {
        self.lock.lock();
        defer self.lock.unlock();

        const pte = self.virt2pte(vaddr, false) orelse unreachable;
        if (pte.p == 0) return error.NotMapped;
        pte.* = @bitCast(pte.getAddress() | flags);

        if (@intFromPtr(self.pml4) == arch.readRegister("cr3")) {
            // TODO: TLB shootdown
            arch.invlpg(vaddr);
        }
    }

    pub fn unmapPage(self: *Self, vaddr: u64) MapError!void {
        self.lock.lock();
        defer self.lock.unlock();

        const pte = self.virt2pte(vaddr, false) orelse unreachable;
        if (pte.p == 0) return error.NotMapped;
        pte.* = @bitCast(0);

        if (@intFromPtr(self.pml4) == arch.readRegister("cr3")) {
            // TODO: TLB shootdown
            arch.invlpg(vaddr);
        }
    }

    pub inline fn cr3(self: *const Self) u64 {
        return @intFromPtr(self.pml4) - hhdm_offset;
    }
};

pub const page_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .free = free,
    },
};

pub var hhdm_offset: u64 = undefined; // set in pmm.zig
pub var kaddr_space: *AddressSpace = undefined;
var tlb_shootdown_vector: u8 = undefined;

pub fn init() MapError!void {
    log.info("hhdm offset: 0x{x}", .{hhdm_offset});

    kaddr_space = AddressSpace.init() catch unreachable;

    for (256..512) |i| {
        _ = kaddr_space.pml4[i].getNextLevel(true);
    }

    try mapSection("text", kaddr_space, PTE.present);
    try mapSection("rodata", kaddr_space, PTE.present | PTE.noexec);
    try mapSection("data", kaddr_space, PTE.present | PTE.writable | PTE.noexec);

    // map the first 4 GiB
    var addr: u64 = 0x1000;
    while (addr < 0x100000000) : (addr += page_size) {
        try kaddr_space.mapPage(addr, addr, PTE.present | PTE.writable);
        try kaddr_space.mapPage(addr + hhdm_offset, addr, PTE.present | PTE.writable | PTE.noexec);
    }

    // map the rest of the memory map
    const memory_map = root.memory_map_request.response.?;
    for (memory_map.entries()) |entry| {
        const base = alignBackward(u64, entry.base, page_size);
        const top = alignForward(u64, entry.base + entry.length, page_size);
        if (top <= 0x100000000) continue;

        var i = base;
        while (i < top) : (i += page_size) {
            if (i < 0x100000000) continue;

            try kaddr_space.mapPage(i, i, PTE.present | PTE.writable);
            try kaddr_space.mapPage(i + hhdm_offset, i, PTE.present | PTE.writable | PTE.noexec);
        }
    }

    // TODO
    // idt.registerHandler(idt.page_fault_vector, pageFaultHandler);
    // idt.setIST(idt.page_fault_vector, 2);

    tlb_shootdown_vector = idt.allocVector();
    idt.registerHandler(tlb_shootdown_vector, tlbShootdownHandler);

    switchPageTable(kaddr_space.cr3());
}

pub inline fn switchPageTable(page_table: u64) void {
    arch.writeRegister("cr3", page_table);
}

inline fn mapSection(comptime section: []const u8, addr_space: *AddressSpace, flags: u64) MapError!void {
    const start: u64 = @intFromPtr(@extern([*]u8, .{ .name = section ++ "_start" }));
    const end: u64 = @intFromPtr(@extern([*]u8, .{ .name = section ++ "_end" }));
    const start_addr = alignBackward(u64, start, page_size);
    const end_addr = alignForward(u64, end, page_size);
    const kaddr = root.kernel_address_request.response.?;

    var addr = start_addr;
    while (addr < end_addr) : (addr += page_size) {
        const paddr = addr - kaddr.virtual_base + kaddr.physical_base;
        try addr_space.mapPage(addr, paddr, flags);
    }
}

fn pageFaultHandler(ctx: *arch.Context) void {
    _ = ctx;
    // TODO: makes cpus crash at some point
}

fn tlbShootdownHandler(ctx: *arch.Context) void {
    _ = ctx;
    defer apic.eoi();

    // TODO
}

// kernel page allocator functions

fn alloc(_: *anyopaque, size: usize, _: u8, _: usize) ?[*]u8 {
    std.debug.assert(size > 0);
    std.debug.assert(size < std.math.maxInt(usize) - page_size);

    const aligned_size = alignForward(usize, size, page_size);
    const pages = @divExact(aligned_size, page_size);
    const address = pmm.alloc(pages, false) orelse return null;
    return @ptrFromInt(address + hhdm_offset);
}

fn resize(_: *anyopaque, buf: []u8, _: u8, new_size: usize, _: usize) bool {
    const aligned_new_size = alignForward(usize, new_size, page_size);
    const aligned_buf_len = alignForward(usize, buf.len, page_size);

    if (aligned_new_size == aligned_buf_len) return true;

    if (aligned_new_size < aligned_buf_len) {
        const address = @intFromPtr(buf.ptr + aligned_new_size);
        const pages = @divExact((aligned_buf_len - aligned_new_size), page_size);
        pmm.free(address - hhdm_offset, pages);
        return true;
    }

    return false;
}

fn free(_: *anyopaque, buf: []u8, _: u8, _: usize) void {
    const aligned_buf_len = alignForward(usize, buf.len, page_size);
    const pages = @divExact(aligned_buf_len, page_size);
    pmm.free(@intFromPtr(buf.ptr) - hhdm_offset, pages);
}
