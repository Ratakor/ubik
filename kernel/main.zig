const std = @import("std");
const builtin = @import("builtin");
const limine = @import("limine");
const ubik = @import("ubik");
pub const arch = @import("arch.zig");
const debug = @import("debug.zig");
const serial = @import("serial.zig");
const event = @import("event.zig");
pub const pmm = @import("mm/pmm.zig");
pub const vmm = @import("mm/vmm.zig");
const acpi = @import("acpi.zig");
pub const sched = @import("sched.zig");
pub const smp = @import("smp.zig");
pub const time = @import("time.zig");
pub const vfs = @import("vfs.zig");
const ps2 = @import("ps2.zig");
const TTY = @import("TTY.zig");
const PageAllocator = @import("mm/PageAllocator.zig");
const lib = @import("lib.zig");

pub usingnamespace lib;

pub const panic = debug.panic;
pub const std_options = struct {
    pub const log_level = if (builtin.mode == .Debug) .debug else .info;
    pub const logFn = debug.log;
};

pub const os = struct {
    pub const system = ubik;
    pub const heap = struct {
        pub const page_allocator = std.mem.Allocator{
            .ptr = undefined,
            .vtable = &PageAllocator.vtable,
        };
    };
};

var gpa = std.heap.GeneralPurposeAllocator(.{
    .thread_safe = false,
    .MutexType = lib.SpinLock,
    .verbose_log = if (builtin.mode == .Debug) true else false,
}){};
pub const allocator = gpa.allocator();
pub var tty0: ?*TTY = null;

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
        else => std.log.warn("unhandled callback: `{}` with args: {}, {}, {}", .{
            cb,
            arg1,
            arg2,
            arg3,
        }),
    }
}

export fn _start() noreturn {
    arch.disableInterrupts();

    serial.init();
    arch.init();
    pmm.init();
    vmm.init();
    acpi.init();
    event.init();
    // syscall.init(); // TODO
    sched.init();
    smp.init();
    time.init();

    const kernel_thread = sched.Thread.initKernel(@ptrCast(&main), null, 1) catch unreachable;
    sched.enqueue(kernel_thread) catch unreachable;
    sched.wait();
}

fn main() noreturn {
    arch.disableInterrupts();
    std.log.debug("in main with cpu {}", .{smp.thisCpu().id});
    arch.enableInterrupts();

    vfs.init(); // TODO
    ps2.init();
    // TODO: init random here instead of in sched?
    // TODO: pci
    // TODO: basic syscalls
    // TODO: basic IPC

    // TODO: start /bin/init <- load elf with std.elf?

    // extern, I think

    // TODO: server with posix syscalls
    // TODO: filesystem
    // TODO: IPC: pipe, socket (TCP, UDP, Unix)

    const fb = framebuffer_request.response.?.framebuffers()[0];
    tty0 = TTY.init(fb.address, fb.width, fb.height, callback) catch unreachable;

    const boot_info = boot_info_request.response.?;
    tty0.?.writer().print("Welcome to Ubik, brought to you by {s} {s} :)\n", .{
        boot_info.name,
        boot_info.version,
    }) catch unreachable;

    arch.disableInterrupts();
    std.log.debug("cpu model: {}", .{smp.thisCpu().cpu_model});
    std.log.debug("cpu family: {}", .{smp.thisCpu().cpu_family});
    std.log.debug("cpu manufacturer: {s}", .{smp.thisCpu().cpu_manufacturer});
    const cpu_name = smp.thisCpu().cpu_name;
    const cpu_name_slice = cpu_name[0 .. std.mem.indexOfScalar(u8, cpu_name[0..], 0) orelse cpu_name.len];
    std.log.debug("cpu name: {s}", .{cpu_name_slice});
    arch.enableInterrupts();

    sched.die();
}
