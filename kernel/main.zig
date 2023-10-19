const std = @import("std");
const builtin = @import("builtin");
const limine = @import("limine");
const ubik = @import("ubik");
const arch = @import("arch.zig");
const debug = @import("debug.zig");
const serial = @import("serial.zig");
const event = @import("event.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const sched = @import("sched.zig");
const smp = @import("smp.zig");
const acpi = @import("acpi.zig");
const ps2 = @import("ps2.zig");
const time = @import("time.zig");
const TTY = @import("TTY.zig");
pub const SpinLock = @import("SpinLock.zig");

pub const panic = debug.panic;
pub const std_options = struct {
    // pub const log_level = .debug;
    pub const logFn = debug.log;
};

pub const os = struct {
    pub const system = ubik;
    pub const heap = struct {
        pub const page_allocator = vmm.page_allocator;
    };
};

var gpa = std.heap.GeneralPurposeAllocator(.{
    .thread_safe = false,
    .MutexType = SpinLock, // TODO: remove?
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
    debug.init() catch |err| {
        std.log.warn("Failed to initialize debug info: {}", .{err});
    };
    arch.init();
    // event.init(); // TODO
    pmm.init();
    vmm.init() catch unreachable; // TODO: mmap
    acpi.init();
    // TODO: init random here instead of in sched?
    sched.init();
    smp.init();
    time.init();

    const kernel_thread = sched.Thread.initKernel(@ptrCast(&main), null, 1) catch unreachable;
    sched.enqueue(kernel_thread) catch unreachable;
    sched.wait();
}

fn main() !void {
    std.log.debug("in main with cpu {}", .{smp.thisCpu().id});

    // ps2.init();
    // TODO: pci
    // TODO: vfs
    // TODO: basic syscalls
    // TODO: basic IPC

    // TODO: start /bin/init <- load elf with std.elf?

    // extern, I think

    // TODO: server with posix syscalls
    // TODO: filesystem
    // TODO: IPC: pipe, socket (TCP, UDP, Unix)

    // const fb = framebuffer_request.response.?.framebuffers()[0];
    // tty0 = TTY.init(fb.address, fb.width, fb.height, callback) catch unreachable;

    // const boot_info = boot_info_request.response.?;
    // tty0.?.writer().print("Welcome to Ubik, brought to you by {s} {s} :)\n", .{
    //     boot_info.name,
    //     boot_info.version,
    // }) catch unreachable;

    // var regs = arch.cpuid(0, 0);
    // std.log.debug("vendor string: {s}{s}{s}", .{
    //     @as([*]const u8, @ptrCast(&regs.ebx))[0..4],
    //     @as([*]const u8, @ptrCast(&regs.edx))[0..4],
    //     @as([*]const u8, @ptrCast(&regs.ecx))[0..4],
    // });

    // regs = arch.cpuid(0x80000000, 0);
    // if (regs.eax >= 0x80000004) {
    //     regs = arch.cpuid(0x80000002, 0);
    //     serial.writer.print("cpu name: {s}{s}{s}{s}", .{
    //         @as([*]const u8, @ptrCast(&regs.eax))[0..4],
    //         @as([*]const u8, @ptrCast(&regs.ebx))[0..4],
    //         @as([*]const u8, @ptrCast(&regs.ecx))[0..4],
    //         @as([*]const u8, @ptrCast(&regs.edx))[0..4],
    //     }) catch unreachable;
    //     regs = arch.cpuid(0x80000003, 0);
    //     serial.writer.print("{s}{s}{s}{s}", .{
    //         @as([*]const u8, @ptrCast(&regs.eax))[0..4],
    //         @as([*]const u8, @ptrCast(&regs.ebx))[0..4],
    //         @as([*]const u8, @ptrCast(&regs.ecx))[0..4],
    //         @as([*]const u8, @ptrCast(&regs.edx))[0..4],
    //     }) catch unreachable;
    //     regs = arch.cpuid(0x80000004, 0);
    //     serial.writer.print("{s}{s}{s}{s}\n", .{
    //         @as([*]const u8, @ptrCast(&regs.eax))[0..4],
    //         @as([*]const u8, @ptrCast(&regs.ebx))[0..4],
    //         @as([*]const u8, @ptrCast(&regs.ecx))[0..4],
    //         @as([*]const u8, @ptrCast(&regs.edx))[0..4],
    //     }) catch unreachable;
    // }

    // const rand = @import("rand.zig");
    // var pcg = rand.Pcg.init(rand.getSeedSlow());
    // inline for (0..8) |_| {
    //     const thread = sched.Thread.initKernel(
    //         @ptrCast(&hihihi),
    //         null,
    //         pcg.random().int(u4),
    //     ) catch unreachable;
    //     sched.enqueue(thread) catch unreachable;
    // }

    arch.halt();
}

fn hihihi() void {
    if (tty0) |tty| {
        tty.writer().writeAll("hihihi\n") catch unreachable;
    } else {
        serial.print("hihihi\n", .{});
    }
    sched.die();
}
