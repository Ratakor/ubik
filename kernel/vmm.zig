const std = @import("std");
const root = @import("root");
const SpinLock = @import("lock.zig").SpinLock;
const cpu = @import("cpu.zig");
const idt = @import("idt.zig");
const tty = @import("tty.zig");
const pmm = @import("pmm.zig");
const log = std.log.scoped(.vmm);

const alignForward = std.mem.alignForward;
const page_size = std.mem.page_size;
pub var higher_half: u64 = undefined;

pub const page_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .free = free,
    },
};

pub const Flags = enum(u64) {
    present = 1 << 0,
    write = 1 << 1,
    user = 1 << 2,
    large = 1 << 7,
    noexec = 1 << 63,
};

pub fn init() void {
    log.info("init", .{});
    higher_half = root.hhdm_request.response.?.offset;
    const kernel_address = root.kernel_address_request.response.?;
    _ = kernel_address;

    // idt.setIST(idt.page_fault_vector, 2);
    idt.registerHandler(idt.page_fault_vector, pageFaultHandler);
}

fn switchPageTable(cr3: u64) void {
    asm volatile (
        \\mov %[cr3], %%cr3
        :
        : [cr3] "r" (cr3),
        : "memory"
    );
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
    return @ptrFromInt(address + higher_half);
}

fn resize(_: *anyopaque, buf: []u8, _: u8, new_size: usize, _: usize) bool {
    const aligned_new_size = alignForward(usize, new_size, page_size);
    const aligned_buf_len = alignForward(usize, buf.len, page_size);

    if (aligned_new_size == aligned_buf_len) return true;

    if (aligned_new_size < aligned_buf_len) {
        const address = @intFromPtr(buf.ptr + aligned_new_size);
        const pages = @divExact((aligned_buf_len - aligned_new_size), page_size);
        pmm.free(address - higher_half, pages);
        return true;
    }

    return false;
}

fn free(_: *anyopaque, buf: []u8, _: u8, _: usize) void {
    const aligned_buf_len = alignForward(usize, buf.len, page_size);
    const pages = @divExact(aligned_buf_len, page_size);
    pmm.free(@intFromPtr(buf.ptr) - higher_half, pages);
}

// TODO: idk
// pub fn toHigherHalf(addr: u64) u64 {
//     return addr + hhdm_offset;
// }
