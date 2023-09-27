const std = @import("std");
const limine = @import("limine");
const serial = @import("serial.zig");
const tty = @import("tty.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const pmem = @import("pmem.zig");
const vmem = @import("vmem.zig");
const debug = @import("debug.zig");

// pub const page_allocator = mem.page_allocator;

export var boot_info_request: limine.BootloaderInfoRequest = .{};
pub export var hhdm_request: limine.HhdmRequest = .{};
pub export var framebuffer_request: limine.FramebufferRequest = .{};
pub export var memory_map_request: limine.MemoryMapRequest = .{};
pub export var kernel_file_request: limine.KernelFileRequest = .{};
// export var module_request: limine.ModuleRequest = .{};
// export var rsdp_request: limine.RsdpRequest = .{};
pub export var kernel_address_request: limine.KernelAddressRequest = .{};

// fn loadFile(name: []const u8) !*limine.File {
//     const module_response = module_request.response.?;
//     for (module_response.modules()) |file| {
//         const path: []u8 = file.path[0..std.mem.len(file.path)];
//         if (std.mem.endsWith(u8, path, name)) {
//             return file;
//         }
//     }

//     return error.FileNotFound;
// }

inline fn halt() noreturn {
    while (true) asm volatile ("hlt");
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @setCold(true);
    tty.foreground = tty.Color.red;
    tty.print("\nKernel panic: ", .{});
    tty.foreground = tty.Color.white;
    tty.print("{s}\n", .{msg});

    debug.printStackIterator(std.debug.StackIterator.init(@returnAddress(), @frameAddress()));

    halt();
}

export fn _start() callconv(.C) noreturn {
    asm volatile ("cli");

    main() catch |err| {
        tty.foreground = tty.Color.red;
        tty.print("\nKernel error: ", .{});
        tty.foreground = tty.Color.white;
        tty.print("{}\n", .{err});

        if (@errorReturnTrace()) |stack_trace| {
            debug.printStackTrace(stack_trace);
        }
    };

    halt();
}

fn main() !void {
    const boot_info = boot_info_request.response.?;
    // const module = module_request.response.?;
    // const rsdp = rsdp_request.response.?;

    // TODO: log when init is successful
    tty.init();

    tty.drawSquares();

    tty.print("Booting Ubik with {s} {s}\n", .{ boot_info.name, boot_info.version });

    tty.print("Hello, World!\n", .{});
    tty.foreground = @enumFromInt(0xBD93F9);
    tty.print("new color of value {X}\n\n", .{@intFromEnum(tty.foreground)});
    tty.foreground = tty.Color.white;

    serial.init();
    gdt.init();
    idt.init();

    asm volatile ("sti");
    // page fault
    const ptr: *u32 = @ptrFromInt(0x800000000);
    ptr.* = 32;
    halt();

    try pmem.init();

    const buf = try pmem.alloc(u8, 1, false);
    defer pmem.free(buf);
    tty.print("{*} {}\n", .{ buf.ptr, buf.len });
    const buf2 = try pmem.alloc(u64, 1, false);
    defer pmem.free(buf2);
    tty.print("{*} {}\n", .{ buf2.ptr, buf2.len });

    try vmem.init();
}
