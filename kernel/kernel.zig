const std = @import("std");
const limine = @import("limine");
const Terminal = @import("Terminal.zig").Terminal;

const KernelError = error{
    EmptyResponse,
};

export var framebuffer_request: limine.FramebufferRequest = .{};
export var memory_map_request: limine.MemoryMapRequest = .{};

// var framebuffer: *volatile limine.Framebuffer = undefined;

// fn loadFile(name: []const u8) !*limine.File {
//     const module_response = module_request.response orelse done();
//     for (module_response.modules()) |file| {
//         const path: []u8 = file.path[0..std.mem.len(file.path)];
//         if (std.mem.endsWith(u8, path, name)) {
//             return file;
//         }
//     }

//     return error.FileNotFound;
// }

fn drawCross(fb: *limine.Framebuffer) void {
    for (0..100) |i| {
        const pixel_offset1 = i * fb.pitch + i * 4;
        const pixel_offset2 = i * fb.pitch + (100 - i) * 4;
        @as(*u32, @ptrCast(@alignCast(fb.address + pixel_offset1))).* = 0xFFFFFFFF;
        @as(*u32, @ptrCast(@alignCast(fb.address + pixel_offset2))).* = 0xFFFFFFFF;
    }

}

/// draw 3 sqares one red, one green and one blue
fn drawSquares(fb: *limine.Framebuffer) void {
    const buf = @as([*]u32, @ptrCast(@alignCast(fb.address)))[0 .. (fb.pitch * fb.height) / 4];
    for (0..20) |y| {
        for (0..20) |x| {
            buf[(x + 10) + (y + 40) * fb.width] = 0x00FF0000; // red
            buf[(x + 40) + (y + 40) * fb.width] = 0x0000FF00; // green
            buf[(x + 70) + (y + 40) * fb.width] = 0x000000FF; // blue
        }
    }
}


// pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace) noreturn {
//     @setCold(true);
//     nosuspend tty.panic("{}", msg);
//     // TODO: dump trace
//     // const first_trace_addr = ret_addr orelse @returnAddress();
//     // std.debug.panicImpl(error_return_trace, first_trace_addr, msg);
// }


export fn _start() callconv(.C) noreturn {
    asm volatile ("cli");

    const framebuffer_response = framebuffer_request.response orelse unreachable;
    // if (framebuffer_response.framebuffer_count < 1) unreachable;
    const framebuffer = framebuffer_response.framebuffers()[0];

    main(framebuffer) catch |err| {
        var terminal: Terminal = .{
            .framebuffer = framebuffer,
            .foreground = 0x00FF0000,
        };
        terminal.clear();
        terminal.writer().print("Kernel failed: {any}", .{err}) catch unreachable;
    };

    while (true) {
        asm volatile ("hlt");
    }
}

// const PageAllocator = struct {
//     std.mem.page_size
// };

fn main(fb: *limine.Framebuffer) !void {
    // drawSquares(fb);

    var terminal: Terminal = .{ .framebuffer = fb };
    const writer = terminal.writer();
    writer.print("Hello, World!\n", .{}) catch unreachable;
    // writer.context.foreground = 0xBD93F9;
    // writer.print("new color of value {X}\n", .{writer.context.foreground}) catch unreachable;

    const memory_map_response = memory_map_request.response orelse return KernelError.EmptyResponse;
    // var buffer: [std.mem.page_size]u8 = undefined;
    // var fba = std.heap.FixedBufferAllocator.init(&buffer);
    // const allocator = fba.allocator();
    // var entries = std.ArrayList(*limine.MemoryMapEntry).init(allocator);
    var total_mem: u64 = 0;
    for (memory_map_response.entries(), 0..) |entry, i| {
        _ = i;
        // switch (entry.kind) {
        //     .usable, .acpi_reclaimable, .bootloader_reclaimable => {
        //         total_mem += entry.length;
        //     },
        //     else => {},
        // }
        if (entry.kind == .usable) {
            total_mem += entry.length;
        }
        // try writer.print("{} {}\n", .{i, entry});
    }

    writer.print("{}\n", .{total_mem}) catch unreachable;

    // for (entries.items) |map| {
    //     try writer.print("{}\n", .{map});
    // }
}
