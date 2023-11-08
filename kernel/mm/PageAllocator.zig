const std = @import("std");
const root = @import("root");
const pmm = root.pmm;
const vmm = root.vmm;
const page_size = std.mem.page_size;
const alignForward = std.mem.alignForward;

pub const vtable = std.mem.Allocator.VTable{
    .alloc = alloc,
    .resize = resize,
    .free = free,
};

fn alloc(_: *anyopaque, size: usize, _: u8, _: usize) ?[*]u8 {
    std.debug.assert(size > 0);
    std.debug.assert(size < std.math.maxInt(usize) - page_size);

    const aligned_size = alignForward(usize, size, page_size);
    const pages = @divExact(aligned_size, page_size);
    const address = pmm.alloc(pages, false) orelse return null;
    return @ptrFromInt(address + vmm.hhdm_offset);
}

fn resize(_: *anyopaque, buf: []u8, _: u8, new_size: usize, _: usize) bool {
    const aligned_new_size = alignForward(usize, new_size, page_size);
    const aligned_buf_len = alignForward(usize, buf.len, page_size);

    if (aligned_new_size == aligned_buf_len) return true;

    if (aligned_new_size < aligned_buf_len) {
        const address = @intFromPtr(buf.ptr + aligned_new_size);
        const pages = @divExact((aligned_buf_len - aligned_new_size), page_size);
        pmm.free(address - vmm.hhdm_offset, pages);
        return true;
    }

    return false;
}

fn free(_: *anyopaque, buf: []u8, _: u8, _: usize) void {
    const aligned_buf_len = alignForward(usize, buf.len, page_size);
    const pages = @divExact(aligned_buf_len, page_size);
    pmm.free(@intFromPtr(buf.ptr) - vmm.hhdm_offset, pages);
}
