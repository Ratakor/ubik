//! Intel Manual 3A: https://cdrdv2.intel.com/v1/dl/getContent/671190

const std = @import("std");
const root = @import("root");
const arch = @import("arch.zig");
const idt = @import("idt.zig");
const pmm = @import("pmm.zig");
const SpinLock = @import("lock.zig").SpinLock;
const log = std.log.scoped(.vmm);

// TODO: flag, remap, fork
// TODO: TLB

const MapError = error{
    OutOfMemory,
    AlreadyMapped,
    NotMapped,
};

// TODO: use a simple u64 instead ?
pub const PageTableEntry = packed struct {
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
};

pub const PageTable = struct {
    entries: [512]PageTableEntry,

    const Self = @This();

    inline fn getEntry(self: *Self, vaddr: u64, allocate: bool) ?*PageTableEntry {
        const pml4_idx = (vaddr & (0x1ff << 39)) >> 39;
        const pml3_idx = (vaddr & (0x1ff << 30)) >> 30;
        const pml2_idx = (vaddr & (0x1ff << 21)) >> 21;
        const pml1_idx = (vaddr & (0x1ff << 12)) >> 12;

        const pml4 = self;
        const pml3 = getNextLevel(pml4, pml4_idx, allocate) orelse return null;
        const pml2 = getNextLevel(pml3, pml3_idx, allocate) orelse return null;
        const pml1 = getNextLevel(pml2, pml2_idx, allocate) orelse return null;

        return &pml1.entries[pml1_idx];
    }

    pub fn mapPage(self: *Self, vaddr: u64, paddr: u64, flags: u64) MapError!void {
        const entry = self.getEntry(vaddr, true) orelse return error.OutOfMemory;
        if (entry.p != 0) return error.AlreadyMapped;
        entry.* = @bitCast(paddr | flags);
    }

    pub fn unmapPage(self: *Self, vaddr: u64) MapError!void {
        const entry = self.getEntry(vaddr, false) orelse return error.OutOfMemory;
        if (entry.p == 0) return error.NotMapped;
        entry.* = @bitCast(0);
    }
};

const Mapping = struct {
    base: usize,
    length: usize,
    offset: isize,
    prot: i32,
    flags: i32,
};

pub const AddressSpace = struct {
    lock: SpinLock = .{},
    page_table: *PageTable,
    mappings: std.ArrayListUnmanaged(Mapping) = .{},
};

pub const page_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .free = free,
    },
};

const alignBackward = std.mem.alignBackward;
const alignForward = std.mem.alignForward;
const page_size = std.mem.page_size;
const pte_present: u64 = 1 << 0;
const pte_writable: u64 = 1 << 1;
const pte_user: u64 = 1 << 2;
const pte_noexec: u64 = 1 << 63;

pub var hhdm_offset: u64 = undefined; // set in pmm.zig
pub var kernel_address_space: AddressSpace = .{ .page_table = undefined };

pub fn init() MapError!void {
    log.info("hhdm offset: 0x{x}", .{hhdm_offset});

    const page_table_phys = pmm.alloc(1, true) orelse unreachable;
    const page_table: *PageTable = @ptrFromInt(page_table_phys + hhdm_offset);

    for (256..512) |i| {
        std.debug.assert(getNextLevel(page_table, i, true) != null);
    }

    try mapSection("text", page_table, pte_present);
    try mapSection("rodata", page_table, pte_present | pte_noexec);
    try mapSection("data", page_table, pte_present | pte_writable | pte_noexec);

    // map the first 4 GiB
    var addr: u64 = 0x1000;
    while (addr < 0x100000000) : (addr += page_size) {
        try page_table.mapPage(addr, addr, pte_present | pte_writable);
        try page_table.mapPage(addr + hhdm_offset, addr, pte_present | pte_writable | pte_noexec);
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

            try page_table.mapPage(i, i, pte_present | pte_writable);
            try page_table.mapPage(i + hhdm_offset, i, pte_present | pte_writable | pte_noexec);
        }
    }

    kernel_address_space.page_table = page_table;

    // TODO
    // idt.registerHandler(idt.page_fault_vector, pageFaultHandler);
    // idt.setIST(idt.page_fault_vector, 2); // ?

    switchPageTable(page_table);
}

pub inline fn switchPageTable(page_table: *PageTable) void {
    switch (arch.arch) {
        .x86_64 => arch.writeRegister("cr3", @intFromPtr(page_table) - hhdm_offset),
        else => unreachable, // TODO
    }
}

fn pageFaultHandler(ctx: *idt.Context) void {
    _ = ctx;
}

inline fn mapSection(comptime section: []const u8, page_table: *PageTable, flags: u64) MapError!void {
    const start: u64 = @intFromPtr(@extern([*]u8, .{ .name = section ++ "_start" }));
    const end: u64 = @intFromPtr(@extern([*]u8, .{ .name = section ++ "_end" }));
    const start_addr = alignBackward(u64, start, page_size);
    const end_addr = alignForward(u64, end, page_size);
    const kaddr = root.kernel_address_request.response.?;

    var addr = start_addr;
    while (addr < end_addr) : (addr += page_size) {
        const paddr = addr - kaddr.virtual_base + kaddr.physical_base;
        try page_table.mapPage(addr, paddr, flags);
    }
}

fn getNextLevel(page_table: *PageTable, idx: usize, allocate: bool) ?*PageTable {
    const entry = &page_table.entries[idx];

    if (entry.p != 0) {
        return @ptrFromInt((@as(u64, entry.address) << 12) + hhdm_offset);
    }

    if (!allocate) {
        return null;
    }

    const new_page_table = pmm.alloc(1, true) orelse return null; // errno = ENOMEM
    entry.* = @bitCast(new_page_table | pte_present | pte_writable | pte_user);
    return @ptrFromInt(new_page_table + hhdm_offset);
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
