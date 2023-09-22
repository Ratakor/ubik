const std = @import("std");
const limine = @import("limine");
const Terminal = @import("Terminal.zig").Terminal;

export var framebuffer_request: limine.FramebufferRequest = .{};
export var rsdp_request: limine.RsdpRequest = .{};
export var module_request: limine.ModuleRequest = .{};
export var memory_map_request: limine.MemoryMapRequest = .{};

export var kernel_address_request: limine.KernelAddressRequest = .{};

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

inline fn done() noreturn {
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}

export fn _start() callconv(.C) noreturn {
    // Ensure we got a framebuffer.
    const framebuffer_response = framebuffer_request.response orelse done();
    if (framebuffer_response.framebuffer_count < 1) done();

    // Get the first framebuffer's information.
    const fb = framebuffer_response.framebuffers()[0];

    // var data = @as([*]u32, @ptrCast(@alignCast(fb.address)))[0 .. fb.pitch * fb.height];
    // draw a cross
    for (0..100) |i| {
        const pixel_offset1 = i * fb.pitch + i * 4;
        const pixel_offset2 = i * fb.pitch + (100 - i) * 4;
        @as(*u32, @ptrCast(@alignCast(fb.address + pixel_offset1))).* = 0xFFFFFFFF;
        @as(*u32, @ptrCast(@alignCast(fb.address + pixel_offset2))).* = 0xFFFFFFFF;
    }

    // draw 3 sqares one red, one green and one blue
    for (0..20) |y| {
        for (0..20) |x| {
            const red_pixel_offset = (y + 20) * fb.pitch + (x + 10) * 4;
            const green_pixel_offset = (y + 20) * fb.pitch + (x + 40) * 4;
            const blue_pixel_offset = (y + 20) * fb.pitch + (x + 70) * 4;
            @as(*u32, @ptrCast(@alignCast(fb.address + red_pixel_offset))).* = 0x00FF0000;
            @as(*u32, @ptrCast(@alignCast(fb.address + green_pixel_offset))).* = 0x0000FF00;
            @as(*u32, @ptrCast(@alignCast(fb.address + blue_pixel_offset))).* = 0x000000FF;
        }
    }

    // draw a string on the screen
    var terminal: Terminal = .{ .framebuffer = fb };
    const writer = terminal.writer();
    writer.print("Hello, World!\n", .{}) catch unreachable;
    writer.writeAll("\n\nOn a new line\n") catch unreachable;
    writer.writeAll("tab\toui :)\n") catch unreachable;
    writer.print("here is a number: {d}\n", .{3}) catch unreachable;
    writer.context.foreground = 0xBD93F9;
    writer.writeAll("new color :D\n") catch unreachable;

    // We're done, just hang...
    done();
}
