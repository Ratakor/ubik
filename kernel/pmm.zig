const std = @import("std");
const root = @import("root");
const vmm = @import("vmm.zig");
const SpinLock = @import("SpinLock.zig");
const log = std.log.scoped(.pmm);
const page_size = std.mem.page_size;

const free_page = false;
// TODO: use u64 and bitwise operation to speed up the process?
var bitmap: []bool = undefined;
var last_idx: u64 = 0;
var usable_pages: u64 = 0;
var used_pages: u64 = 0;
var reserved_pages: u64 = 0;
var lock: SpinLock = .{}; // TODO: remove lock on pmm and only use
//                                 root.allocator for risky allocations,
//                                 or remove lock on root.allocator?

pub fn init() void {
    const memory_map = root.memory_map_request.response.?;
    const hhdm_offset = root.hhdm_request.response.?.offset;

    vmm.hhdm_offset = hhdm_offset;
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
    bitmap = for (entries) |entry| {
        if (entry.kind == .usable and entry.length >= aligned_size) {
            const ptr = @as([*]bool, @ptrFromInt(entry.base + hhdm_offset));
            entry.length -= aligned_size;
            entry.base += aligned_size;
            break ptr[0..bitmap_size];
        }
    } else unreachable;
    @memset(bitmap, !free_page);

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

pub fn reclaimMemory() void {
    const memory_map = root.memory_map_request.response.?;

    for (memory_map.entries()) |entry| {
        if (entry.kind == .bootloader_reclaimable) {
            const pages = entry.length / page_size;
            usable_pages += pages;
            reserved_pages -= pages;
            free(entry.base, pages);

            log.info("reclaimed {} pages at 0x{x}", .{ pages, entry.base });
        }
    }
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

pub fn alloc(pages: usize, comptime zero: bool) ?u64 {
    lock.lock();
    defer lock.unlock();

    const last = last_idx;
    const address = innerAlloc(pages, bitmap.len) orelse
        innerAlloc(pages, last) orelse return null;

    used_pages += pages;

    if (comptime zero) {
        const ptr: [*]u8 = @ptrFromInt(address + vmm.hhdm_offset);
        const slice = ptr[0 .. pages * page_size];
        @memset(slice, 0);
    }

    return address;
}

pub fn free(address: u64, pages: usize) void {
    lock.lock();
    defer lock.unlock();

    const page = address / page_size;
    for (page..page + pages) |i| {
        bitmap[i] = free_page;
    }
    used_pages -= pages;
}
