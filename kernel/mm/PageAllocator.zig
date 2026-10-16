const std = @import("std");
const root = @import("root");
const pmm = root.pmm;
const vmm = root.vmm;
const page_size = pmm.page_size;
const alignForward = std.mem.alignForward;
const Alignment = std.mem.Alignment;

pub const vtable: std.mem.Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

fn alloc(_: *anyopaque, size: usize, alignment: Alignment, _: usize) ?[*]u8 {
    std.debug.assert(size > 0);
    const padded = std.math.add(usize, size, page_size - 1) catch return null;
    const pages = padded / page_size;
    const alignment_bytes = @max(alignment.toByteUnits(), page_size);
    const extra_pages = alignment_bytes / page_size - 1;
    const total_pages = std.math.add(usize, pages, extra_pages) catch return null;
    _ = std.math.mul(usize, total_pages, page_size) catch return null;
    const physical = pmm.alloc(total_pages, false) orelse return null;
    // HHDM preserves page boundaries; trim whole pages, never byte prefixes.
    const virtual = physical + vmm.hhdm_offset;
    const aligned = alignForward(usize, virtual, alignment_bytes);
    const leading_pages = (aligned - virtual) / page_size;
    if (leading_pages != 0) pmm.free(physical, leading_pages);
    const trailing_pages = extra_pages - leading_pages;
    if (trailing_pages != 0) pmm.free(physical + (leading_pages + pages) * page_size, trailing_pages);
    return @ptrFromInt(aligned);
}

fn resize(_: *anyopaque, buf: []u8, _: Alignment, new_size: usize, _: usize) bool {
    std.debug.assert(new_size > 0);
    const padded = std.math.add(usize, new_size, page_size - 1) catch return false;
    const aligned_new_size = padded / page_size * page_size;
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

fn remap(context: *anyopaque, buf: []u8, alignment: Alignment, new_size: usize, ret_addr: usize) ?[*]u8 {
    return if (resize(context, buf, alignment, new_size, ret_addr)) buf.ptr else null;
}

fn free(_: *anyopaque, buf: []u8, _: Alignment, _: usize) void {
    const aligned_buf_len = alignForward(usize, buf.len, page_size);
    const pages = @divExact(aligned_buf_len, page_size);
    pmm.free(@intFromPtr(buf.ptr) - vmm.hhdm_offset, pages);
}
