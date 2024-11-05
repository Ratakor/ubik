//! Intel Manual 3A: https://cdrdv2.intel.com/v1/dl/getContent/671190
//! https://wiki.osdev.org/TLB

const std = @import("std");
const root = @import("root");
const ubik = @import("ubik");
const arch = root.arch;
const idt = arch.idt;
const apic = arch.apic;
const pmm = root.pmm;
const smp = root.smp;
const sched = root.sched;
const SpinLock = root.SpinLock;
const log = std.log.scoped(.vmm);
const alignBackward = std.mem.alignBackward;
const alignForward = std.mem.alignForward;
const page_size = std.mem.page_size;

// TODO: mapRange/unmapRange?
// TODO: move paging code to paging.zig
// TODO: use ArenaAllocator for vmm, especially where there is a lot of
//       allocation in a loop or batch alloc/dealloc

pub const MapError = error{
    OutOfMemory,
    AlreadyMapped,
    NotMapped,
};

/// Page Table Entry
pub const PTE = packed struct(u64) {
    present: bool,
    writable: bool,
    user: bool,
    write_through: bool,
    cache_disable: bool,
    accessed: bool,
    dirty: bool,
    /// page attribute table
    pat: bool,
    global: bool,
    ignored1: u3,
    /// between u24 and u39 based on MAXPHYADDR from cpuid, the rest must be 0s
    address: u40,
    ignored2: u7,
    protection_key: u4,
    execute_disable: bool,

    // TODO: remove and replace usage with named decl
    const PRESENT: u64 = 1 << 0;
    const WRITABLE: u64 = 1 << 1;
    const USER: u64 = 1 << 2;
    const NOEXEC: u64 = 1 << 63;

    pub inline fn getAddress(self: PTE) u64 {
        return @as(u64, self.address) << 12;
    }

    pub inline fn getFlags(self: PTE) u64 {
        return @as(u64, @bitCast(self)) & 0xf800_0000_0000_0fff;
    }

    inline fn getNextLevel(self: *PTE, allocate: bool) MapError![*]PTE {
        if (self.present) {
            return @ptrFromInt(self.getAddress() + hhdm_offset);
        }

        if (!allocate) {
            return error.NotMapped;
        }

        const new_page_table = pmm.alloc(1, true) orelse return error.OutOfMemory;
        self.* = @bitCast(new_page_table | PRESENT | WRITABLE | USER);
        return @ptrFromInt(new_page_table + hhdm_offset);
    }
};

pub const PageFaultError = packed struct(u32) {
    present: bool,
    write: bool,
    user: bool,
    reserved_write: bool,
    instruction_fetch: bool,
    protection_key: bool,
    shadow_stack: bool,
    reserved1: u8,
    software_guard_extensions: bool,
    reserved2: u16,
};

// TODO: replace
// TODO: init and deinit func?
const MMapRangeGlobal = struct {
    shadow_addr_space: *AddressSpace,
    locals: std.ArrayListUnmanaged(*MMapRangeLocal) = .{}, // HashMap?
    // resource: *Resource, // TODO: vnode?
    base: usize,
    length: usize,
    offset: ubik.off_t,
};

// TODO: replace
// TODO: init and deinit func?
const MMapRangeLocal = struct {
    addr_space: *AddressSpace,
    global: *MMapRangeGlobal,
    base: usize,
    length: usize,
    offset: ubik.off_t,
    prot: i32,
    flags: ubik.MAP,
};

// TODO: improve
const Addr2Range = struct {
    range: *MMapRangeLocal,
    memory_page: usize,
    file_page: usize,

    fn init(addr_space: *AddressSpace, vaddr: u64) error{RangeNotFound}!Addr2Range {
        for (addr_space.mmap_ranges.items) |local_range| {
            if (vaddr >= local_range.base and vaddr < local_range.base + local_range.length) {
                const memory_page = vaddr / page_size;
                // TODO: divTrunc?
                const offset = @divExact(local_range.offset, page_size);
                // TODO: ugly
                const file_page: usize = @intCast(offset + @as(isize, @intCast(memory_page - local_range.base / page_size)));
                return .{
                    .range = local_range,
                    .memory_page = memory_page,
                    .file_page = file_page,
                };
            }
        }
        return error.RangeNotFound;
    }
};

// TODO: rename Pagemap?
pub const AddressSpace = struct {
    pml4: *[512]PTE,
    lock: SpinLock = .{},
    mmap_ranges: std.ArrayListUnmanaged(*MMapRangeLocal) = .{}, // HashMap?

    pub fn init() !*AddressSpace {
        const addr_space = try root.allocator.create(AddressSpace);
        errdefer root.allocator.destroy(addr_space);

        const pml4_phys = pmm.alloc(1, true) orelse return error.OutOfMemory;
        addr_space.* = .{ .pml4 = @ptrFromInt(pml4_phys + hhdm_offset) };
        @memset(addr_space.pml4[0..256], @bitCast(@as(u64, 0)));
        @memcpy(addr_space.pml4[256..512], kaddr_space.pml4[256..512]);

        return addr_space;
    }

    fn destroyLevel(pml: [*]PTE, start: usize, end: usize, level: usize) void {
        if (level == 0) return;

        for (start..end) |i| {
            const next_level = pml[i].getNextLevel(false) catch unreachable; // TODO: continue
            destroyLevel(next_level, 0, 512, level - 1);
        }

        pmm.free(@intFromPtr(pml) - hhdm_offset, 1);
    }

    pub fn deinit(self: *AddressSpace) void {
        for (self.mmap_ranges.items) |local_range| {
            self.munmap(local_range.base, local_range.length) catch unreachable;
        }
        self.lock.lock(); // TODO: useless or may cause deadlocks?
        destroyLevel(self.pml4, 0, 256, 4);
        root.allocator.destroy(self);
    }

    // TODO
    pub fn fork(self: *AddressSpace) !*AddressSpace {
        self.lock.lock();
        defer self.lock.unlock();
        errdefer self.lock.unlock();

        const new_addr_space = try AddressSpace.init();
        errdefer new_addr_space.deinit();

        for (self.mmap_ranges.items) |local_range| {
            const global_range = local_range.global;

            const new_local_range = try root.allocator.create(MMapRangeLocal);
            new_local_range.* = local_range.*;
            new_local_range.addr_space = new_addr_space; // TODO?

            // if (global_range.resource) |res| {
            //     res.refcount += 1;
            // }

            try new_addr_space.mmap_ranges.append(root.allocator, new_local_range);

            if (local_range.flags.TYPE == ubik.MAP_TYPE.SHARED) {
                try global_range.locals.append(root.allocator, new_local_range);
                var i = local_range.base;
                while (i < local_range.base + local_range.length) : (i += page_size) {
                    const old_pte = self.virt2pte(i, false) catch unreachable; // TODO: continue?
                    const new_pte = new_addr_space.virt2pte(i, true) catch unreachable; // TODO: free
                    new_pte.* = old_pte.*;
                }
            } else {
                const new_global_range = try root.allocator.create(MMapRangeGlobal);
                errdefer root.allocator.destroy(new_global_range);
                new_global_range.* = .{
                    .shadow_addr_space = try AddressSpace.init(),
                    .base = global_range.base,
                    .length = global_range.length,
                    .offset = global_range.offset,
                };
                errdefer new_global_range.shadow_addr_space.deinit();
                try new_global_range.locals.append(root.allocator, new_local_range);
                errdefer new_global_range.locals.deinit(root.allocator);

                if (local_range.flags.ANONYMOUS == false) {
                    @panic("Non anonymous fork");
                }

                var i = local_range.base;
                while (i < local_range.base + local_range.length) : (i += page_size) {
                    const old_pte = self.virt2pte(i, false) catch unreachable; // TODO: continue?
                    if (old_pte.present == false) continue;
                    const new_pte = new_addr_space.virt2pte(i, true) catch unreachable; // TODO: free
                    const new_spte = new_global_range.shadow_addr_space.virt2pte(i, true) catch unreachable; // TODO: free

                    const old_page = old_pte.getAddress();
                    const new_page = pmm.alloc(1, false) orelse unreachable; // TODO: free
                    const slice_old_page = @as([*]u8, @ptrFromInt(old_page + hhdm_offset))[0..page_size];
                    const slice_new_page = @as([*]u8, @ptrFromInt(new_page + hhdm_offset))[0..page_size];
                    @memcpy(slice_new_page, slice_old_page);
                    new_pte.* = @bitCast(old_pte.getFlags() | new_page);
                    new_spte.* = new_pte.*;
                }
            }
        }

        return new_addr_space;
    }

    pub fn virt2pte(self: *const AddressSpace, vaddr: u64, allocate: bool) MapError!*PTE {
        const pml4_idx = (vaddr & (0x1ff << 39)) >> 39;
        const pml3_idx = (vaddr & (0x1ff << 30)) >> 30;
        const pml2_idx = (vaddr & (0x1ff << 21)) >> 21;
        const pml1_idx = (vaddr & (0x1ff << 12)) >> 12;

        const pml4 = self.pml4;
        const pml3 = try pml4[pml4_idx].getNextLevel(allocate);
        const pml2 = try pml3[pml3_idx].getNextLevel(allocate);
        const pml1 = try pml2[pml2_idx].getNextLevel(allocate);

        return &pml1[pml1_idx];
    }

    pub fn virt2phys(self: *const AddressSpace, vaddr: u64) MapError!u64 {
        const pte = try self.virt2pte(vaddr, false);
        if (!pte.present) return error.NotMapped;
        return pte.getAddress();
    }

    pub fn mapPage(self: *AddressSpace, vaddr: u64, paddr: u64, flags: u64) MapError!void {
        self.lock.lock();
        defer self.lock.unlock();

        // TODO: when virt2pte fails the memory it allocated is not freed
        const pte = try self.virt2pte(vaddr, true);
        if (pte.present) return error.AlreadyMapped;
        pte.* = @bitCast(paddr | flags);
        self.flush(vaddr);
    }

    pub fn remapPage(self: *AddressSpace, vaddr: u64, flags: u64) MapError!void {
        self.lock.lock();
        defer self.lock.unlock();

        const pte = try self.virt2pte(vaddr, false);
        if (!pte.present) return error.NotMapped;
        pte.* = @bitCast(pte.getAddress() | flags);
        self.flush(vaddr);
    }

    pub fn unmapPage(self: *AddressSpace, vaddr: u64, lock: bool) MapError!void {
        if (lock) self.lock.lock();
        defer if (lock) self.lock.unlock();

        const pte = try self.virt2pte(vaddr, false);
        if (!pte.present) return error.NotMapped;
        pte.* = @bitCast(@as(u64, 0));
        self.flush(vaddr);
    }

    inline fn mapSection(self: *AddressSpace, comptime section: []const u8, flags: u64) void {
        const start: u64 = @intFromPtr(@extern([*]u8, .{ .name = section ++ "_start" }));
        const end: u64 = @intFromPtr(@extern([*]u8, .{ .name = section ++ "_end" }));
        const start_addr = alignBackward(u64, start, page_size);
        const end_addr = alignForward(u64, end, page_size);
        const kaddr = root.kernel_address_request.response.?;

        var addr = start_addr;
        while (addr < end_addr) : (addr += page_size) {
            const paddr = addr - kaddr.virtual_base + kaddr.physical_base;
            self.mapPage(addr, paddr, flags) catch unreachable;
        }
    }

    pub inline fn cr3(self: *const AddressSpace) u64 {
        return @intFromPtr(self.pml4) - hhdm_offset;
    }

    // TODO: lock?
    fn flush(self: *AddressSpace, vaddr: u64) void {
        // std.debug.assert(arch.interruptState() == false);
        const old_state = arch.toggleInterrupts(false);
        defer _ = arch.toggleInterrupts(old_state);

        // TODO: is `if` useful?
        if (self.cr3() == arch.readRegister("cr3")) {
            arch.invlpg(vaddr);
        }

        if (!smp.initialized) return;

        const this_cpu = smp.thisCpu();
        for (smp.cpus) |*cpu| {
            if (cpu == this_cpu) continue;

            cpu.tlb_shootdown_cr3 = self.cr3();
            asm volatile ("" ::: "memory");
            apic.sendIPI(cpu.lapic_id, .{ .vector = tlb_shootdown_ipi_vector });
        }
    }

    pub fn mmapRange(
        self: *AddressSpace,
        vaddr: u64,
        paddr: u64,
        len: usize,
        prot: i32,
        flags: i32,
    ) !void {
        // flags |= MAP.ANONYMOUS; // TODO

        const aligned_vaddr = alignBackward(u64, vaddr, page_size);
        const aligned_len = alignForward(u64, len + (vaddr - aligned_vaddr), page_size);

        const global_range = try root.allocator.create(MMapRangeGlobal);
        errdefer root.allocator.destroy(global_range);
        global_range.shadow_addr_space = try AddressSpace.init();
        errdefer global_range.shadow_addr_space.deinit();
        global_range.base = aligned_vaddr;
        global_range.length = aligned_len;
        global_range.locals = .{};
        errdefer global_range.locals.deinit(root.allocator);

        const local_range = try root.allocator.create(MMapRangeLocal);
        errdefer root.allocator.destroy(local_range);
        local_range.addr_space = self;
        local_range.global = global_range;
        local_range.base = aligned_vaddr;
        local_range.length = aligned_len;
        local_range.prot = prot;
        local_range.flags = flags;

        try global_range.locals.append(root.allocator, local_range);

        {
            self.lock.lock();
            errdefer self.lock.unlock();
            try self.mmap_ranges.append(root.allocator, local_range);
            self.lock.unlock();
        }

        var i: usize = 0;
        while (i < aligned_len) : (i += page_size) {
            try mmapPageInRange(global_range, aligned_vaddr + i, paddr + i, prot);
            // TODO: if mmapPageInRange fails we're in trouble
        }
    }

    // TODO
    pub fn munmap(self: *AddressSpace, addr: u64, constlen: usize) !void {
        if (constlen == 0) return error.EINVAL;
        const len = alignForward(usize, constlen, page_size);

        var i = addr;
        while (i < addr + len) : (i += page_size) {
            const range = Addr2Range.init(self, i) catch continue;
            const local_range = range.range;
            const global_range = local_range.global;

            const snip_start = i;
            while (true) {
                i += page_size;
                if (i >= local_range.base + local_range.length or i >= addr + len) {
                    break;
                }
            }
            const snip_end = i;
            const snip_size = snip_end - snip_start;

            self.lock.lock();
            errdefer self.lock.unlock();

            if (snip_start > local_range.base and snip_end < local_range.base + local_range.length) {
                const postsplit_range = try root.allocator.create(MMapRangeLocal); // if this fail we're in bad state
                errdefer root.allocator.destroy(postsplit_range);
                postsplit_range.addr_space = local_range.addr_space;
                postsplit_range.global = global_range;
                postsplit_range.base = snip_end;
                postsplit_range.length = (local_range.base + local_range.length) - snip_end;
                postsplit_range.offset = local_range.offset + @as(isize, @intCast(snip_end - local_range.base));
                postsplit_range.prot = local_range.prot;
                postsplit_range.flags = local_range.flags;

                try self.mmap_ranges.append(root.allocator, postsplit_range);

                local_range.length -= postsplit_range.length;
            }

            var j = snip_start;
            while (j < snip_end) : (j += page_size) {
                try self.unmapPage(j, false);
            }

            if (snip_size == local_range.length) {
                for (self.mmap_ranges.items, 0..) |mmap_range, k| {
                    if (mmap_range == local_range) {
                        _ = self.mmap_ranges.swapRemove(k);
                        break;
                    }
                }
            }

            self.lock.unlock();

            if (snip_size == local_range.length and global_range.locals.items.len == 1) {
                if (local_range.flags.ANONYMOUS) {
                    var k = global_range.base;
                    while (k < global_range.base + global_range.length) : (k += page_size) {
                        const paddr = global_range.shadow_addr_space.virt2phys(j) catch continue;
                        try global_range.shadow_addr_space.unmapPage(j, false); // if this fail we're in really bad state
                        pmm.free(paddr, 1);
                    }
                } else {
                    // TODO: unamp res
                }

                root.allocator.destroy(local_range);
            } else {
                if (snip_start == local_range.base) {
                    local_range.offset += @intCast(snip_size);
                    local_range.base = snip_end;
                }
                local_range.length -= snip_size;
            }
        }
    }
};

pub var hhdm_offset: u64 = undefined; // set in pmm.zig
pub var kaddr_space: *AddressSpace = undefined;
var tlb_shootdown_ipi_vector: u8 = undefined;

pub fn init() void {
    log.info("hhdm offset: 0x{x}", .{hhdm_offset});

    kaddr_space = root.allocator.create(AddressSpace) catch unreachable;
    const pml4_phys = pmm.alloc(1, true) orelse unreachable;
    kaddr_space.* = .{ .pml4 = @ptrFromInt(pml4_phys + hhdm_offset) };

    @memset(kaddr_space.pml4[0..256], @bitCast(@as(u64, 0)));
    for (256..512) |i| {
        _ = kaddr_space.pml4[i].getNextLevel(true) catch unreachable;
    }

    kaddr_space.mapSection("text", PTE.PRESENT);
    kaddr_space.mapSection("rodata", PTE.PRESENT | PTE.NOEXEC);
    kaddr_space.mapSection("data", PTE.PRESENT | PTE.WRITABLE | PTE.NOEXEC);

    // map the first 4 GiB
    var addr: u64 = 0x1000;
    while (addr < 0x100000000) : (addr += page_size) {
        kaddr_space.mapPage(addr, addr, PTE.PRESENT | PTE.WRITABLE) catch unreachable;
        kaddr_space.mapPage(addr + hhdm_offset, addr, PTE.PRESENT | PTE.WRITABLE | PTE.NOEXEC) catch unreachable;
    }

    // map the rest of the memory map
    const memory_map = root.memory_map_request.response.?;
    for (memory_map.entries()) |entry| {
        if (entry.kind == .reserved) continue;

        const base = alignBackward(u64, entry.base, page_size);
        const top = alignForward(u64, entry.base + entry.length, page_size);
        if (top <= 0x100000000) continue;

        var i = base;
        while (i < top) : (i += page_size) {
            if (i < 0x100000000) continue;

            kaddr_space.mapPage(i, i, PTE.PRESENT | PTE.WRITABLE) catch unreachable;
            kaddr_space.mapPage(i + hhdm_offset, i, PTE.PRESENT | PTE.WRITABLE | PTE.NOEXEC) catch unreachable;
        }
    }

    tlb_shootdown_ipi_vector = idt.allocVector();
    idt.registerHandler(tlb_shootdown_ipi_vector, tlbShootdownHandler);
    switchPageTable(kaddr_space.cr3());
}

pub inline fn switchPageTable(page_table: u64) void {
    arch.writeRegister("cr3", page_table);
}

pub fn handlePageFault(cr2: u64, reason: PageFaultError) !void {
    if (reason.present) return error.PageProtectionViolation;

    const addr_space = sched.currentThread().process.addr_space;
    addr_space.lock.lock();
    const range = try Addr2Range.init(addr_space, cr2);
    addr_space.lock.unlock();

    // TODO: enable interrupts?

    const local_range = range.range;
    const page = if (local_range.flags.ANONYMOUS)
        pmm.alloc(1, true) orelse return error.OutOfMemory
    else
        @panic("TODO: map files");

    try mmapPageInRange(local_range.global, range.memory_page * page_size, page, local_range.prot);
}

fn mmapPageInRange(global: *MMapRangeGlobal, vaddr: u64, paddr: u64, prot: i32) !void {
    var flags = PTE.PRESENT | PTE.USER;
    if ((prot & ubik.PROT.WRITE) != 0) {
        flags |= PTE.WRITABLE;
    }
    if ((prot & ubik.PROT.EXEC) == 0) {
        flags |= PTE.NOEXEC;
    }

    try global.shadow_addr_space.mapPage(vaddr, paddr, flags);

    for (global.locals.items) |local_range| {
        if (vaddr >= local_range.base and vaddr < local_range.base + local_range.length) {
            try local_range.addr_space.mapPage(vaddr, paddr, flags);
        }
    }
}

fn tlbShootdownHandler(ctx: *arch.Context) callconv(.SysV) void {
    _ = ctx;

    if (smp.thisCpu().tlb_shootdown_cr3 == arch.readRegister("cr3")) {
        // TODO: invlpg cpu.tlb_Shootdown_addr?
        arch.writeRegister("cr3", arch.readRegister("cr3"));
    }

    apic.eoi();
}
