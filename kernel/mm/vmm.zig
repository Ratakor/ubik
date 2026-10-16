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
            const next_level = pml[i].getNextLevel(false) catch continue;
            destroyLevel(next_level, 0, 512, level - 1);
        }

        pmm.free(@intFromPtr(pml) - hhdm_offset, 1);
    }

    pub fn deinit(self: *AddressSpace) void {
        const interrupt_state = lockVmm(&range_lock);
        defer unlockVmm(&range_lock, interrupt_state);
        self.deinitLocked();
    }

    fn deinitLocked(self: *AddressSpace) void {
        while (self.mmap_ranges.items.len != 0) {
            const local = self.mmap_ranges.items[self.mmap_ranges.items.len - 1];
            self.munmapLocked(local.base, local.length) catch unreachable;
        }
        self.mmap_ranges.deinit(root.allocator);
        // The caller must have retired this address space from all CPUs.
        const interrupt_state = lockVmm(&self.lock);
        destroyLevel(self.pml4, 0, 256, 4);
        unlockVmm(&self.lock, interrupt_state);
        root.allocator.destroy(self);
    }

    pub fn fork(self: *AddressSpace) !*AddressSpace {
        const range_interrupt_state = lockVmm(&range_lock);
        defer unlockVmm(&range_lock, range_interrupt_state);
        const interrupt_state = lockVmm(&self.lock);
        defer unlockVmm(&self.lock, interrupt_state);

        const child = try AddressSpace.init();
        errdefer child.deinitLocked();
        try child.mmap_ranges.ensureUnusedCapacity(root.allocator, self.mmap_ranges.items.len);

        for (self.mmap_ranges.items) |local| {
            const new_local = blk: {
                const entry = try root.allocator.create(MMapRangeLocal);
                errdefer root.allocator.destroy(entry);
                entry.* = local.*;
                entry.addr_space = child;
                if (local.flags.TYPE == .SHARED) {
                    try local.global.locals.append(root.allocator, entry);
                } else {
                    if (!local.flags.ANONYMOUS) @panic("Non anonymous fork");
                    const global = try root.allocator.create(MMapRangeGlobal);
                    errdefer root.allocator.destroy(global);
                    global.* = .{
                        .shadow_addr_space = try AddressSpace.init(),
                        .base = local.global.base,
                        .length = local.global.length,
                        .offset = local.global.offset,
                    };
                    errdefer global.shadow_addr_space.deinitLocked();
                    try global.locals.append(root.allocator, entry);
                    entry.global = global;
                }
                child.mmap_ranges.appendAssumeCapacity(entry);
                break :blk entry;
            };

            var page = local.base;
            while (page < local.base + local.length) : (page += page_size) {
                const source_space = if (local.flags.TYPE == .SHARED) self else local.global.shadow_addr_space;
                const source = source_space.virt2pte(page, false) catch |err| switch (err) {
                    error.NotMapped => continue,
                    else => return err,
                };
                if (!source.present) continue;
                const destination = try child.virt2pte(page, true);
                if (local.flags.TYPE == .SHARED) {
                    destination.* = source.*;
                } else {
                    const shadow = try new_local.global.shadow_addr_space.virt2pte(page, true);
                    const physical = pmm.alloc(1, false) orelse return error.OutOfMemory;
                    const old_bytes = @as([*]const u8, @ptrFromInt(source.getAddress() + hhdm_offset))[0..page_size];
                    const new_bytes = @as([*]u8, @ptrFromInt(physical + hhdm_offset))[0..page_size];
                    @memcpy(new_bytes, old_bytes);
                    destination.* = @bitCast(protectionFlags(local.prot) | physical);
                    shadow.* = @bitCast(PTE.PRESENT | physical);
                }
            }
        }
        return child;
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
        const interrupt_state = lockVmm(&self.lock);
        defer unlockVmm(&self.lock, interrupt_state);

        // TODO: when virt2pte fails the memory it allocated is not freed
        const pte = try self.virt2pte(vaddr, true);
        if (pte.present) return error.AlreadyMapped;
        pte.* = @bitCast(paddr | flags);
        self.flush(vaddr);
    }

    pub fn remapPage(self: *AddressSpace, vaddr: u64, flags: u64) MapError!void {
        const interrupt_state = lockVmm(&self.lock);
        defer unlockVmm(&self.lock, interrupt_state);

        const pte = try self.virt2pte(vaddr, false);
        if (!pte.present) return error.NotMapped;
        pte.* = @bitCast(pte.getAddress() | flags);
        self.flush(vaddr);
    }

    pub fn unmapPage(self: *AddressSpace, vaddr: u64, lock: bool) MapError!void {
        const interrupt_state = if (lock) lockVmm(&self.lock) else arch.toggleInterrupts(false);
        defer if (lock) unlockVmm(&self.lock, interrupt_state) else {
            _ = arch.toggleInterrupts(interrupt_state);
        };

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

    fn flush(self: *AddressSpace, vaddr: u64) void {
        const old_state = lockVmm(&shootdown_lock);
        defer unlockVmm(&shootdown_lock, old_state);

        // Higher-half page tables are shared by every address space.
        if (vaddr >= 0xffff800000000000 or self.cr3() == arch.readRegister("cr3")) {
            arch.invlpg(vaddr);
        }
        if (!smp.initialized) return;

        shootdown_cr3 = self.cr3();
        shootdown_addr = vaddr;
        const this_cpu = smp.thisCpu();
        for (smp.cpus) |*cpu| {
            if (cpu == this_cpu) continue;
            @atomicStore(u64, &cpu.tlb_shootdown_cr3, 1, .release);
            waitForIpiDelivery();
            apic.sendIPI(cpu.lapic_id, .{ .vector = tlb_shootdown_ipi_vector });
            waitForIpiDelivery();
        }
        for (smp.cpus) |*cpu| {
            if (cpu == this_cpu) continue;
            while (@atomicLoad(u64, &cpu.tlb_shootdown_cr3, .acquire) != 0) {
                std.atomic.spinLoopHint();
            }
        }
    }

    pub fn mmapRange(
        self: *AddressSpace,
        vaddr: u64,
        paddr: u64,
        len: usize,
        prot: i32,
        flags: ubik.MAP,
    ) !void {
        if (len == 0 or vaddr % page_size != paddr % page_size) return error.EINVAL;
        const base = alignBackward(u64, vaddr, page_size);
        const physical = alignBackward(u64, paddr, page_size);
        const size = std.math.add(usize, len, vaddr - base) catch return error.EINVAL;
        const padded = std.math.add(usize, size, page_size - 1) catch return error.EINVAL;
        const length = alignBackward(usize, padded, page_size);
        const end = std.math.add(u64, base, length) catch return error.EINVAL;
        _ = std.math.add(u64, physical, length) catch return error.EINVAL;
        if (end > 0x800000000000) return error.EINVAL;

        const range_interrupt_state = lockVmm(&range_lock);
        defer unlockVmm(&range_lock, range_interrupt_state);
        const interrupt_state = lockVmm(&self.lock);
        defer unlockVmm(&self.lock, interrupt_state);
        for (self.mmap_ranges.items) |other| {
            if (base < other.base + other.length and other.base < end) return error.AlreadyMapped;
        }
        var page = base;
        while (page < end) : (page += page_size) {
            const pte = self.virt2pte(page, false) catch continue;
            if (pte.present) return error.AlreadyMapped;
        }
        try self.mmap_ranges.ensureUnusedCapacity(root.allocator, 1);

        const global = try root.allocator.create(MMapRangeGlobal);
        errdefer root.allocator.destroy(global);
        global.* = .{
            .shadow_addr_space = try AddressSpace.init(),
            .base = base,
            .length = length,
            .offset = 0,
        };
        errdefer global.shadow_addr_space.deinitLocked();
        errdefer global.locals.deinit(root.allocator);
        const local = try root.allocator.create(MMapRangeLocal);
        errdefer root.allocator.destroy(local);
        local.* = .{
            .addr_space = self,
            .global = global,
            .base = base,
            .length = length,
            .offset = 0,
            .prot = prot,
            .flags = flags,
        };
        try global.locals.append(root.allocator, local);

        // Physical pages remain the callers ownership until the whole mapping
        // succeeds. Rollback removes translations but must not free those pages.
        var mapped: usize = 0;
        errdefer {
            var offset: usize = 0;
            while (offset < mapped) : (offset += page_size) {
                const pte = self.virt2pte(base + offset, false) catch unreachable;
                pte.* = @bitCast(@as(u64, 0));
                self.flush(base + offset);
            }
        }
        while (mapped < length) : (mapped += page_size) {
            const pte = try self.virt2pte(base + mapped, true);
            const shadow = try global.shadow_addr_space.virt2pte(base + mapped, true);
            shadow.* = @bitCast((physical + mapped) | PTE.PRESENT);
            pte.* = @bitCast((physical + mapped) | protectionFlags(prot));
            self.flush(base + mapped);
        }
        self.mmap_ranges.appendAssumeCapacity(local);
    }

    pub fn munmap(self: *AddressSpace, addr: u64, constlen: usize) !void {
        const interrupt_state = lockVmm(&range_lock);
        defer unlockVmm(&range_lock, interrupt_state);
        try self.munmapLocked(addr, constlen);
    }

    // range_lock protects both lists and all local/global range lifetimes.
    fn munmapLocked(self: *AddressSpace, addr: u64, constlen: usize) !void {
        if (constlen == 0 or addr % page_size != 0) return error.EINVAL;
        const padded = std.math.add(usize, constlen, page_size - 1) catch return error.EINVAL;
        const len = alignBackward(usize, padded, page_size);
        const end = std.math.add(u64, addr, len) catch return error.EINVAL;
        const interrupt_state = lockVmm(&self.lock);
        defer unlockVmm(&self.lock, interrupt_state);

        var i = addr;
        while (i < end) {
            const range = Addr2Range.init(self, i) catch {
                i += page_size;
                continue;
            };
            const local = range.range;
            const global = local.global;
            const old_end = local.base + local.length;
            const snip_end = @min(old_end, end);
            const anonymous = local.flags.ANONYMOUS;

            // Reserve both registrations before changing either list or PTEs.
            if (i > local.base and snip_end < old_end) {
                const tail = try root.allocator.create(MMapRangeLocal);
                errdefer root.allocator.destroy(tail);
                try self.mmap_ranges.ensureUnusedCapacity(root.allocator, 1);
                try global.locals.ensureUnusedCapacity(root.allocator, 1);
                tail.* = local.*;
                tail.base = snip_end;
                tail.length = old_end - snip_end;
                tail.offset += @intCast(snip_end - local.base);
                self.mmap_ranges.appendAssumeCapacity(tail);
                global.locals.appendAssumeCapacity(tail);
            }

            if (i == local.base and snip_end == old_end) {
                for (self.mmap_ranges.items, 0..) |entry, index| {
                    if (entry == local) {
                        _ = self.mmap_ranges.swapRemove(index);
                        break;
                    }
                }
                for (global.locals.items, 0..) |entry, index| {
                    if (entry == local) {
                        _ = global.locals.swapRemove(index);
                        break;
                    }
                }
                root.allocator.destroy(local);
            } else if (i == local.base) {
                local.offset += @intCast(snip_end - local.base);
                local.base = snip_end;
                local.length = old_end - snip_end;
            } else {
                local.length = i - local.base;
            }

            var page = i;
            while (page < snip_end) : (page += page_size) {
                self.unmapPage(page, false) catch |err| switch (err) {
                    error.NotMapped => {},
                    else => unreachable,
                };
                // Split ranges and forked aliases may still own this backing.
                const retained = for (global.locals.items) |other| {
                    if (page >= other.base and page < other.base + other.length) break true;
                } else false;
                if (!retained) {
                    const physical = global.shadow_addr_space.virt2phys(page) catch continue;
                    global.shadow_addr_space.unmapPage(page, true) catch unreachable;
                    // unmapPage waits for all TLB acknowledgments before reuse.
                    if (anonymous) pmm.free(physical, 1);
                }
            }
            if (global.locals.items.len == 0) {
                global.shadow_addr_space.deinitLocked();
                global.locals.deinit(root.allocator);
                root.allocator.destroy(global);
            }
            i = snip_end;
        }
    }
};

pub var hhdm_offset: u64 = undefined; // set in pmm.zig
pub var kaddr_space: *AddressSpace = undefined;
var tlb_shootdown_ipi_vector: u8 = undefined;
var range_lock: SpinLock = .{};
var shootdown_lock: SpinLock = .{};
var shootdown_cr3: u64 = undefined;
var shootdown_addr: u64 = undefined;

// All VMM lock waiters must service shootdowns: a sender can hold the very
// address-space lock a target is waiting for with interrupts disabled.
fn lockVmm(lock: *SpinLock) bool {
    const old_state = arch.toggleInterrupts(false);
    while (!lock.tryLock()) {
        serviceShootdown();
        std.atomic.spinLoopHint();
    }
    return old_state;
}

fn unlockVmm(lock: *SpinLock, old_state: bool) void {
    lock.unlock();
    _ = arch.toggleInterrupts(old_state);
}

// sendIPI does not wait for the xAPIC ICR delivery-status bit. Keep this
// local until the APIC API provides that guarantee for all its callers.
fn waitForIpiDelivery() void {
    const icr_low: *volatile u32 = @ptrFromInt(apic.lapic_base + 0x300);
    while ((icr_low.* & (1 << 12)) != 0) std.atomic.spinLoopHint();
}

fn serviceShootdown() void {
    if (!smp.initialized) return;
    const cpu = smp.thisCpu();
    if (@atomicLoad(u64, &cpu.tlb_shootdown_cr3, .acquire) == 0) return;
    if (shootdown_addr >= 0xffff800000000000 or shootdown_cr3 == arch.readRegister("cr3")) {
        arch.invlpg(shootdown_addr);
    }
    @atomicStore(u64, &cpu.tlb_shootdown_cr3, 0, .release);
}

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
    if (reason.present or reason.reserved_write or reason.protection_key or reason.shadow_stack or reason.software_guard_extensions) {
        return error.PageProtectionViolation;
    }
    const interrupt_state = lockVmm(&range_lock);
    defer unlockVmm(&range_lock, interrupt_state);
    const addr_space = sched.currentThread().process.addr_space;
    const range = try Addr2Range.init(addr_space, cr2);
    const local = range.range;
    if (local.prot == ubik.PROT.NONE or
        (reason.write and (local.prot & ubik.PROT.WRITE) == 0) or
        (reason.instruction_fetch and (local.prot & ubik.PROT.EXEC) == 0) or
        (!reason.write and !reason.instruction_fetch and (local.prot & (ubik.PROT.READ | ubik.PROT.WRITE)) == 0))
    {
        return error.PageProtectionViolation;
    }

    const page = range.memory_page * page_size;
    const address_interrupt_state = lockVmm(&addr_space.lock);
    defer unlockVmm(&addr_space.lock, address_interrupt_state);
    const pte = try addr_space.virt2pte(page, true);
    if (pte.present) {
        // Another CPU may have resolved this fault before we acquired the lock.
        addr_space.flush(page);
        return;
    }
    const shadow = try local.global.shadow_addr_space.virt2pte(page, true);
    if (!shadow.present) {
        if (!local.flags.ANONYMOUS) @panic("TODO: map files");
        const physical = pmm.alloc(1, true) orelse return error.OutOfMemory;
        // No fallible work remains once ownership is transferred to the shadow.
        shadow.* = @bitCast(physical | PTE.PRESENT);
    }
    pte.* = @bitCast(shadow.getAddress() | protectionFlags(local.prot));
    addr_space.flush(page);
}

fn protectionFlags(prot: i32) u64 {
    var flags: u64 = PTE.USER;
    if (prot != ubik.PROT.NONE) flags |= PTE.PRESENT;
    if ((prot & ubik.PROT.WRITE) != 0) flags |= PTE.WRITABLE;
    if ((prot & ubik.PROT.EXEC) == 0) flags |= PTE.NOEXEC;
    return flags;
}

fn tlbShootdownHandler(ctx: *arch.Context) callconv(.SysV) void {
    _ = ctx;

    serviceShootdown();

    apic.eoi();
}
