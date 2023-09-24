const std = @import("std");
const vmem = @import("vmem.zig");

const Allocator = std.mem.Allocator;
const page_size = std.mem.page_size;

// TODO
pub const page_allocator = Allocator{
    .ptr = undefined, // TODO
    .vtable = &vtable,
};

const vtable = Allocator.VTable{
    .alloc = alloc,
    .resize = resize,
    .free = free,
};

fn alloc(_: *anyopaque, size: usize, _: u8, _: usize) ?[*]u8 {
    const aligned_size = std.mem.alignForward(usize, size, page_size);

    // TODO
    _ = aligned_size;

    return null;
}

fn resize(_: *anyopaque, buf: []u8, _: u8, new_size: usize, _: usize) bool {
    const aligned_new_size = std.mem.alignForward(usize, new_size, page_size);
    const aligned_buf_len = std.mem.alignForward(usize, buf.len, page_size);

    if (aligned_new_size == aligned_buf_len) return true;

    if (aligned_new_size < aligned_buf_len) {
        const ptr = buf.ptr + aligned_new_size;
        // TODO
        _ = ptr;
        // vmem.free(@alignCast(ptr[0 .. aligned_buf_len - aligned_new_size]));
        return true;
    }

    return false;
}

/// Free and invalidate a buffer.
///
/// `buf.len` must equal the most recent length returned by `alloc` or
/// given to a successful `resize` call.
///
/// `buf_align` must equal the same value that was passed as the
/// `ptr_align` parameter to the original `alloc` call.
///
/// `ret_addr` is optionally provided as the first return address of the
/// allocation call stack. If the value is `0` it means no return address
/// has been provided.
fn free(_: *anyopaque, buf: []u8, _: u8, _: usize) void {
    // TODO
    _ = buf;
    // const aligned_buf_len = std.mem.alignForward(usize, buf.len, page_size);
    // vmem.free(@alignCast(ptr[0 .. aligned_buf_len]));

}
