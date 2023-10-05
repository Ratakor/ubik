const std = @import("std");
const builtin = @import("builtin");
const limine = @import("limine");
const arch = @import("arch.zig");
const debug = @import("debug.zig");
const serial = @import("serial.zig");
const tty = @import("tty.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const cpu = @import("cpu.zig");
const acpi = @import("acpi.zig");
const apic = @import("apic.zig");
const ps2 = @import("ps2.zig");
const SpinLock = @import("lock.zig").SpinLock;

pub const std_options = struct {
    pub const logFn = debug.log;
};

pub const os = struct {
    pub const system = struct {};
    pub const heap = struct {
        pub const page_allocator = vmm.page_allocator;
    };
};

var gpa = std.heap.GeneralPurposeAllocator(.{
    .thread_safe = false,
    .MutexType = SpinLock,
    .verbose_log = if (builtin.mode == .Debug) true else false,
}){};
pub const allocator = gpa.allocator();

pub export var boot_info_request: limine.BootloaderInfoRequest = .{};
pub export var hhdm_request: limine.HhdmRequest = .{};
pub export var framebuffer_request: limine.FramebufferRequest = .{};
pub export var memory_map_request: limine.MemoryMapRequest = .{};
pub export var kernel_file_request: limine.KernelFileRequest = .{};
pub export var kernel_address_request: limine.KernelAddressRequest = .{};
pub export var rsdp_request: limine.RsdpRequest = .{};
pub export var smp_request: limine.SmpRequest = .{};
pub export var boot_time_request: limine.BootTimeRequest = .{};
pub export var module_request: limine.ModuleRequest = .{};

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @setCold(true);
    arch.disableInterrupts();
    tty.resetColor();
    tty.Color.setFg(.red);
    tty.write("\nKernel panic: ");
    tty.resetColor();
    tty.print("{s}\n", .{msg});
    debug.printStackIterator(std.debug.StackIterator.init(@returnAddress(), @frameAddress()));
    tty.hideCursor();
    arch.halt();
}

export fn _start() callconv(.C) noreturn {
    main() catch |err| {
        tty.print("\x1b[m\x1b[91m\nKernel error:\x1b[m {s}\n", .{@errorName(err)});
        if (@errorReturnTrace()) |stack_trace| {
            debug.printStackTrace(stack_trace);
        }
        tty.hideCursor();
    };

    arch.halt();
}

fn main() !void {
    arch.disableInterrupts();
    defer arch.enableInterrupts();

    serial.init();
    tty.init() catch unreachable;

    const boot_info = boot_info_request.response.?;
    tty.print("Booting Ubik with {s} {s}\n", .{ boot_info.name, boot_info.version });

    debug.init() catch |err| {
        std.log.warn("Failed to initialize debug info: {}\n", .{err});
    };

    gdt.init();
    idt.init();
    // TODO: event.init();

    pmm.init();
    vmm.init(); // TODO: next step I swear

    // TODO: proc + TSS
    // TODO: sched
    // TODO: threads <-- with priority level ? <- have a list of thread based
    // on priority level and state (accoriding to https://wiki.osdev.org/Going_further_on_x86
    cpu.init(); // TODO

    acpi.init();
    apic.init(); // TODO: local apic
    // TODO: time (pit)
    ps2.init();
    // TODO: pci

    // TODO: filesystem <-- extern

    // TODO: start /bin/init <- load elf with std.elf
}
