const std = @import("std");
const builtin = @import("builtin");
const SpinLock = @import("root").SpinLock;
const PageAllocator = @import("PageAllocator.zig");
const pmm = @import("pmm.zig");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const HeapAllocator = @This();

// Zig's hosted mutex and self-unwinder are unavailable in the kernel. Keep
// allocation safety checks, with our IRQ-safe lock and physical-page backend.
backend: std.heap.DebugAllocator(.{
    .thread_safe = false,
    .stack_trace_frames = 0,
    .verbose_log = builtin.mode == .Debug,
    .backing_allocator_zeroes = false,
    .page_size = pmm.page_size,
}) = .{ .backing_allocator = .{ .ptr = undefined, .vtable = &PageAllocator.vtable } },
lock: SpinLock = .{},

pub fn allocator(self: *HeapAllocator) Allocator {
    return .{ .ptr = self, .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    } };
}

fn alloc(context: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *HeapAllocator = @ptrCast(@alignCast(context));
    self.lock.lock();
    defer self.lock.unlock();
    return self.backend.allocator().rawAlloc(len, alignment, ret_addr);
}

fn resize(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *HeapAllocator = @ptrCast(@alignCast(context));
    self.lock.lock();
    defer self.lock.unlock();
    return self.backend.allocator().rawResize(memory, alignment, new_len, ret_addr);
}

fn remap(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *HeapAllocator = @ptrCast(@alignCast(context));
    self.lock.lock();
    defer self.lock.unlock();
    return self.backend.allocator().rawRemap(memory, alignment, new_len, ret_addr);
}

fn free(context: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *HeapAllocator = @ptrCast(@alignCast(context));
    self.lock.lock();
    defer self.lock.unlock();
    self.backend.allocator().rawFree(memory, alignment, ret_addr);
}
