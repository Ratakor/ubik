const std = @import("std");
const root = @import("root");
const SpinLock = @import("lock.zig").SpinLock;
const cpu = @import("cpu.zig");
const arch = @import("arch.zig");
const idt = @import("idt.zig");
const tty = @import("tty.zig");
const pmm = @import("pmm.zig");
const log = std.log.scoped(.vmm);

const alignForward = std.mem.alignForward;
const page_size = std.mem.page_size;
pub var hhdm_offset: u64 = undefined; // set in pmm.zig

pub const page_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .free = free,
    },
};

// TODO
const PageTableEntry = packed struct {
    p: u1, // present
    rw: u1, // read/write
    us: u1, // user/supervisor
    pwt: u1, // write-through
    pcd: u1, // cache disable
    a: u1, // accessed
    d: u1, // dirty
    pat: u1, // page attribute table
    g: u1, // global
    avl: u3, // available
    address: u20,
    // reserved
    // avl
    // pk
    // xd
};

pub const Flags = enum(u64) {
    present = 1 << 0,
    write = 1 << 1,
    user = 1 << 2,
    large = 1 << 7,
    noexec = 1 << 63,
};

pub fn init() void {
    log.info("hhdm offset = 0x{x}", .{hhdm_offset});

    const kernel_address = root.kernel_address_request.response.?;
    _ = kernel_address;

    // idt.setIST(idt.page_fault_vector, 2);
    idt.registerHandler(idt.page_fault_vector, pageFaultHandler);
}

fn switchPageTable(cr3: u64) void {
    arch.writeRegister("cr3", cr3);
}

fn pageFaultHandler(ctx: *cpu.Context) void {
    _ = ctx;
    tty.print("TODO: handle Page fault\n", .{});
}

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

// TODO: idk
// pub fn toHigherHalf(addr: u64) u64 {
//     return addr + hhdm_offset;
// }
