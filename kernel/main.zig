const std = @import("std");
const limine = @import("limine");
const debug = @import("debug.zig");
const serial = @import("serial.zig");
const tty = @import("tty.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const mem = @import("mem.zig");
const time = @import("time.zig");

pub const std_options = struct {
    pub const logFn = debug.log;
};

export var boot_info_request: limine.BootloaderInfoRequest = .{};
pub export var hhdm_request: limine.HhdmRequest = .{};
pub export var framebuffer_request: limine.FramebufferRequest = .{};
pub export var memory_map_request: limine.MemoryMapRequest = .{};
pub export var kernel_file_request: limine.KernelFileRequest = .{};
// export var module_request: limine.ModuleRequest = .{};
// export var rsdp_request: limine.RsdpRequest = .{};
pub export var kernel_address_request: limine.KernelAddressRequest = .{};
pub export var boot_time_request: limine.BootTimeRequest = .{};

inline fn halt() noreturn {
    while (true) asm volatile ("hlt");
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @setCold(true);
    tty.resetColor();
    tty.Color.setFg(.red);
    tty.write("\nKernel panic: ");
    tty.resetColor();
    tty.print("{s}\n", .{msg});
    debug.printStackIterator(std.debug.StackIterator.init(@returnAddress(), @frameAddress()));
    halt();
}

export fn _start() callconv(.C) noreturn {
    asm volatile ("cli");

    main() catch |err| {
        tty.print("\x1b[m\x1b[91m\nKernel error:\x1b[m {s}\n", .{@errorName(err)});
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

    // TODO: log when init is successful (with serial or tty idk)
    tty.init() catch unreachable;
    serial.init();

    tty.print("Booting Ubik with {s} {s}\n", .{ boot_info.name, boot_info.version });

    debug.init() catch |err| {
        std.log.warn("Failed to initialize debug info: {}\n", .{err});
    };

    gdt.init();
    idt.init();
    // TODO: init events <-- for interrupts
    // TODO: interrupt controller (pic or apic)
    // TODO: PS/2 -> handle keyboard/mouse <-- extern

    try pmm.init();
    try vmm.init(); // TODO
    // try mem.init(); // TODO: heap allocator -> use gpa

    // TODO: apic
    // TODO: acpi
    // TODO: pci
    time.init(); // TODO: timers (pit ?)

    // TODO: proc
    // TODO: scheduler
    // TODO: cpu
    // TODO: threads <-- with priority level ? <- have a list of thread based
    // on priority level and state (accoriding to https://wiki.osdev.org/Going_further_on_x86

    // TODO: filesystem <-- extern

    // TODO: start /bin/init <- load elf with std.elf

    tty.ColorRGB.setFgStr("#bd93f9");
    tty.print("Hello, World!\n", .{});
    tty.Color256.setBg(69);
    tty.Color.setFg(.bright_black);
    tty.print("realtime: {}\n", .{time.realtime});
    tty.resetColor();
    const buf = try pmm.alloc(1, false);
    defer pmm.free(buf);
    tty.print("allocated a buffer of size {} and address = {*}\n", .{ buf.len, buf.ptr });

    asm volatile ("sti");
    @breakpoint();
}
