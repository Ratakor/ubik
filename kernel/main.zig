const std = @import("std");
const builtin = @import("builtin");
const limine = @import("limine");
const ubik = @import("ubik");
const arch = @import("arch.zig");
const debug = @import("debug.zig");
const serial = @import("serial.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const event = @import("event.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const proc = @import("proc.zig");
const sched = @import("sched.zig");
const cpu = @import("cpu.zig");
const acpi = @import("acpi.zig");
const apic = @import("apic.zig");
const ps2 = @import("ps2.zig");
const pit = @import("pit.zig");
const term = ubik.term;
const TTY = @import("TTY.zig");
const SpinLock = @import("lock.zig").SpinLock;

pub const std_options = struct {
    pub const logFn = debug.log;
};

pub const os = struct {
    pub const system = ubik;
    pub const heap = struct {
        pub const page_allocator = vmm.page_allocator;
    };
};

var gpa = std.heap.GeneralPurposeAllocator(.{
    .MutexType = SpinLock,
    .verbose_log = if (builtin.mode == .Debug) true else false,
}){};
pub const allocator = gpa.allocator();
pub var tty0: *TTY = undefined;
pub var writer: TTY.Writer = undefined;

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

fn callback(tty: *TTY, cb: TTY.Callback, arg1: u64, arg2: u64, arg3: u64) void {
    _ = tty;
    // TODO: https://github.com/limine-bootloader/limine/blob/v5.x-branch/PROTOCOL.md#terminal-callback
    switch (cb) {
        else => std.log.warn("unhandled callback: `{}` with args: {}, {}, {}", .{ cb, arg1, arg2, arg3 }),
    }
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @setCold(true);
    arch.disableInterrupts();
    term.resetColor(writer) catch unreachable;
    term.Color.setFg(writer, .red) catch unreachable;
    writer.writeAll("\nKernel panic: ") catch unreachable;
    term.resetColor(writer) catch unreachable;
    writer.print("{s}\n", .{msg}) catch unreachable;
    debug.printStackIterator(std.debug.StackIterator.init(@returnAddress(), @frameAddress()));
    term.hideCursor(writer) catch unreachable;
    arch.halt();
}

export fn _start() callconv(.C) noreturn {
    main() catch |err| {
        writer.print("\x1b[m\x1b[91m\nKernel error:\x1b[m {any}\n", .{err}) catch unreachable;
        if (@errorReturnTrace()) |stack_trace| {
            debug.printStackTrace(stack_trace);
        }
        term.hideCursor(writer) catch unreachable;
    };

    const regs = arch.cpuid(0, 0);
    std.log.debug("vendor string: {s}{s}{s}", .{
        @as([*]const u8, @ptrCast(&regs.ebx))[0..4],
        @as([*]const u8, @ptrCast(&regs.edx))[0..4],
        @as([*]const u8, @ptrCast(&regs.ecx))[0..4],
    });

    arch.halt();
}

fn main() !void {
    arch.disableInterrupts();
    defer arch.enableInterrupts();

    serial.init();
    debug.init() catch |err| {
        std.log.warn("Failed to initialize debug info: {}\n", .{err});
    };

    gdt.init();
    idt.init();
    event.init(); // TODO

    pmm.init();
    vmm.init() catch unreachable; // TODO

    proc.init(); // TODO + TSS
    sched.init(); // TODO
    // TODO: threads <- with priority level ? <- have a list of thread based
    // on priority level and state (accoriding to https://wiki.osdev.org/Going_further_on_x86
    cpu.init(); // TODO

    acpi.init();
    apic.init(); // TODO: local apic timers for sched
    pit.init();

    const fb = framebuffer_request.response.?.framebuffers()[0];
    tty0 = TTY.init(fb.address, fb.width, fb.height, callback) catch unreachable;
    writer = tty0.writer();

    const boot_info = boot_info_request.response.?;
    writer.print("Welcome to Ubik, brought to you by {s} {s} :)\n", .{
        boot_info.name,
        boot_info.version,
    }) catch unreachable;

    ps2.init();
    // TODO: pci

    // TODO: process
    // TODO: basic syscalls + lib for them (zig + C)
    // TODO: server with more syscall for compat with Linux

    // TODO: filesystem <- extern

    // TODO: socket -> TCP/IP

    // TODO: start /bin/init <- load elf with std.elf
}
