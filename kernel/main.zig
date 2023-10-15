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

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @setCold(true);

    arch.disableInterrupts();

    const StackIterator = std.debug.StackIterator;
    const fmt = "\x1b[m\x1b[31m\nKernel panic:\x1b[m {s}\n";
    if (tty0) |tty| {
        const writer = tty.writer();
        writer.print(fmt, .{msg}) catch unreachable;
        debug.printStackIterator(writer, StackIterator.init(@returnAddress(), @frameAddress()));
        ubik.term.hideCursor(writer) catch unreachable;
    } else {
        serial.print(fmt, .{msg});
        debug.printStackIterator(serial.writer, StackIterator.init(@returnAddress(), @frameAddress()));
    }

    arch.halt();
}

export fn _start() callconv(.C) noreturn {
    arch.disableInterrupts();

    serial.init();
    debug.init() catch |err| {
        std.log.warn("Failed to initialize debug info: {}\n", .{err});
    };
    arch.init();
    event.init(); // TODO: init event handlers
    pmm.init();
    vmm.init() catch unreachable; // TODO: mmap
    acpi.init();
    // TODO: init random here instead of in sched?
    sched.init(); // TODO
    smp.init();
    time.init();

    // TODO: crash due to page fault
    // const kernel_thread = sched.Thread.initKernel(@ptrCast(&main), null) catch unreachable;
    // kernel_thread.enqueue(1) catch unreachable;

    arch.enableInterrupts();
    sched.wait();
}

fn main() !void {
    const fb = framebuffer_request.response.?.framebuffers()[0];
    tty0 = TTY.init(fb.address, fb.width, fb.height, callback) catch unreachable;

    const boot_info = boot_info_request.response.?;
    tty0.?.writer().print("Welcome to Ubik, brought to you by {s} {s} :)\n", .{
        boot_info.name,
        boot_info.version,
    }) catch unreachable;

    ps2.init();
    // TODO: pci
    // TODO: vfs
    // TODO: basic syscalls

    // TODO: setup Inter-Processor Interrupts
    // TODO: basic IPC

    // TODO: start /bin/init <- load elf with std.elf

    // extern, I think
    // TODO: server with posix syscalls
    // TODO: filesystem
    // TODO: IPC: pipe, socket (TCP, UDP, Unix)

    var regs = arch.cpuid(0, 0);
    std.log.debug("vendor string: {s}{s}{s}", .{
        @as([*]const u8, @ptrCast(&regs.ebx))[0..4],
        @as([*]const u8, @ptrCast(&regs.edx))[0..4],
        @as([*]const u8, @ptrCast(&regs.ecx))[0..4],
    });

    regs = arch.cpuid(0x80000000, 0);
    if (regs.eax >= 0x80000004) {
        regs = arch.cpuid(0x80000002, 0);
        serial.writer.print("cpu name: {s}{s}{s}{s}", .{
            @as([*]const u8, @ptrCast(&regs.eax))[0..4],
            @as([*]const u8, @ptrCast(&regs.ebx))[0..4],
            @as([*]const u8, @ptrCast(&regs.ecx))[0..4],
            @as([*]const u8, @ptrCast(&regs.edx))[0..4],
        }) catch unreachable;
        regs = arch.cpuid(0x80000003, 0);
        serial.writer.print("{s}{s}{s}{s}", .{
            @as([*]const u8, @ptrCast(&regs.eax))[0..4],
            @as([*]const u8, @ptrCast(&regs.ebx))[0..4],
            @as([*]const u8, @ptrCast(&regs.ecx))[0..4],
            @as([*]const u8, @ptrCast(&regs.edx))[0..4],
        }) catch unreachable;
        regs = arch.cpuid(0x80000004, 0);
        serial.writer.print("{s}{s}{s}{s}\n", .{
            @as([*]const u8, @ptrCast(&regs.eax))[0..4],
            @as([*]const u8, @ptrCast(&regs.ebx))[0..4],
            @as([*]const u8, @ptrCast(&regs.ecx))[0..4],
            @as([*]const u8, @ptrCast(&regs.edx))[0..4],
        }) catch unreachable;
    }

    const rand = @import("rand.zig");
    var pcg = rand.Pcg.init(rand.getSeedSlow());
    inline for (0..8) |_| {
        const thread = sched.Thread.initKernel(@ptrCast(&hihihi), null) catch unreachable;
        thread.enqueue(pcg.random().int(u4)) catch unreachable;
    }
}

fn hihihi() void {
    if (tty0) |tty| {
        tty.writer().writeAll("hihihi\n") catch unreachable;
    }
    sched.dequeueAndDie();
}
