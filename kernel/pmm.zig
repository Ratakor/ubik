const std = @import("std");
const root = @import("root");
const SpinLock = @import("lock.zig").SpinLock;
const log = std.log.scoped(.pmm);

const page_size = std.mem.page_size;
const free_page = false;

// TODO slab allocator instead of page frame allocator ?
// TODO use u64 and logical operation to speed up the process ?
var bitmap: []bool = undefined;
var last_idx: u64 = 0;
var usable_pages: u64 = 0;
var used_pages: u64 = 0;
var reserved_pages: u64 = 0;
var lock: SpinLock = .{};

pub fn init() !void {
    const memory_map = root.memory_map_request.response.?;
    const hhdm = root.hhdm_request.response.?.offset;
    const entries = memory_map.entries();

    var highest_addr: u64 = 0;

    // calculate the size of the bitmap
    for (entries) |entry| {
        log.info("base: 0x{x}, length: 0x{x}, kind: {s}", .{
            entry.base,
            entry.length,
            @tagName(entry.kind),
        });

        if (entry.kind == .usable) {
            usable_pages += entry.length / page_size;
            highest_addr = @max(highest_addr, entry.base + entry.length);
        } else {
            reserved_pages += entry.length / page_size;
        }
    }

    const bitmap_size = highest_addr / page_size;
    const aligned_size = std.mem.alignForward(u64, bitmap_size / 8, page_size);

    log.info("highest address: 0x{x}", .{highest_addr});
    log.info("bitmap size: {} bits", .{bitmap_size});

    // find a hole in the memory map to fit the bitmap
    var bitmap_ptr: ?[*]bool = null;
    for (entries) |entry| {
        if (entry.kind == .usable and entry.length >= aligned_size) {
            bitmap_ptr = @as([*]bool, @ptrFromInt(entry.base + hhdm));
            entry.length -= aligned_size;
            entry.base += aligned_size;
            break;
        }
    }

    if (bitmap_ptr) |ptr| {
        bitmap = ptr[0..bitmap_size];
        @memset(bitmap, !free_page);
    } else {
        return error.BitMapTooBig;
    }

    for (entries) |entry| {
        if (entry.kind != .usable) continue;

        var i: u64 = 0;
        while (i < entry.length) : (i += page_size) {
            const idx = (entry.base + i) / page_size;
            bitmap[idx] = free_page;
        }
    }

    log.info("usable memory: {} MiB", .{(usable_pages * page_size) / 1024 / 1024});
    log.info("reserved memory: {} MiB", .{(reserved_pages * page_size) / 1024 / 1024});
}

fn innerAlloc(pages: usize, limit: u64) ?u64 {
    var p: usize = 0;

    for (last_idx..limit) |i| {
        if (bitmap[i] == free_page) {
            p += 1;
            if (p == pages) {
                last_idx = i + 1;
                const page = last_idx - pages;
                for (page..last_idx) |j| {
                    bitmap[j] = !free_page;
                }
                return page * page_size;
            }
        } else {
            p = 0;
        }
    }
    last_idx = 0;
    return null;
}

// TODO: use many-item pointer or u64 instead of slice because div/mul is expensive ?
// TODO: add a system to log everything (in this case allocation) in debug mode ?

pub fn alloc(pages: usize, comptime zero: bool) ![]u8 {
    lock.lock();
    defer lock.unlock();

    const last = last_idx;
    const address = innerAlloc(pages, bitmap.len) orelse
        innerAlloc(pages, last) orelse return error.OutOfMemory;

    used_pages += pages;
    const ptr: [*]u8 = @ptrFromInt(address);
    const slice = ptr[0 .. pages * page_size];
    comptime if (zero) @memset(slice, 0);

    return slice;
}

pub fn free(slice: []u8) void {
    lock.lock();
    defer lock.unlock();

    const pages = @divExact(slice.len, page_size);
    const page = @intFromPtr(slice.ptr) / page_size;
    for (page..page + pages) |i| {
        bitmap[i] = free_page;
    }
    used_pages -= pages;
}
