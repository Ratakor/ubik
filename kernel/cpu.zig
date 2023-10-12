const std = @import("std");
const limine = @import("limine");
const root = @import("root");
const arch = @import("arch.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const vmm = @import("vmm.zig");
const SpinLock = @import("lock.zig").SpinLock;
const log = std.log.scoped(.cpu);

// TODO: move smp stuff to smp.zig

pub const Context = extern struct {
    ds: u64,
    es: u64,
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rbp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    isr_vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

/// Task State Segment
pub const TSS = extern struct {
    reserved0: u32 align(1) = 0,
    rsp: [3]u64 align(1),
    reserved1: u64 align(1) = 0,
    ist: [7]u64 align(1),
    reserved2: u64 align(1) = 0,
    reserved3: u16 align(1) = 0,
    iopb: u16 align(1),
};

pub const CpuLocal = struct {
    cpu_number: usize,
    bsp: bool, // is bootstrap processor
    // active: bool,
    // last_run_queue_index: u32,
    lapic_id: u32,
    lapic_freq: u64,
    tss: TSS,
    // idle_thread: *Thread,
    // tlb_shootdown_lock: SpinLock,
    // tlb_shootdown_done: SpinLock,
    // tlb_shootdown_cr3: usize, // TODO: volatile
};

const PAT = packed struct {
    // zig fmt: off
    pa0: u3, reserved0: u5,
    pa1: u3, reserved1: u5,
    pa2: u3, reserved2: u5,
    pa3: u3, reserved3: u5,
    pa4: u3, reserved4: u5,
    pa5: u3, reserved5: u5,
    pa6: u3, reserved6: u5,
    pa7: u3, reserved7: u5,
    // zig fmt: on

    const Flags = enum(u64) {
        uncacheable = 0,
        write_combining = 1,
        write_through = 4,
        write_protected = 5,
        write_back = 6,
        uncached = 7,
    };
};

pub var bsp_lapic_id: u32 = undefined;
pub var cpus_local: []CpuLocal = undefined;
var cpus_started: usize = 0;

// TODO
// pub var sysenter: bool = false;
// const cpu_stack_size = 0x10000;
// pub var fpu_storage_size: usize = 0;
// pub var fpu_save: *const fn (*Context) void = undefined;
// pub var fpu_restore: *const fn (*Context) void = undefined;

pub fn init() void {
    const smp = root.smp_request.response.?;
    bsp_lapic_id = smp.bsp_lapic_id;
    cpus_local = root.allocator.alloc(CpuLocal, smp.cpu_count) catch unreachable;
    @memset(cpus_local, std.mem.zeroes(CpuLocal));
    log.info("{} processors detected", .{cpus_local.len});

    // TODO: lapic irq handler

    for (smp.cpus(), cpus_local, 0..) |cpu, *cpu_local, i| {
        cpu.extra_argument = @intFromPtr(cpu_local);
        cpu_local.cpu_number = i;

        if (cpu.lapic_id != bsp_lapic_id) {
            cpu.goto_address = @ptrCast(&trampoline);
        } else {
            cpu_local.bsp = true;
            trampoline(cpu);
        }
    }

    while (cpus_started != cpus_local.len) {
        std.atomic.spinLoopHint();
    }
}

pub fn this() *CpuLocal {}

fn trampoline(smp_info: *limine.SmpInfo) callconv(.C) void {
    const cpu_local: *CpuLocal = @ptrFromInt(smp_info.extra_argument);
    cpu_local.lapic_id = smp_info.lapic_id;

    initFeatures();

    gdt.reload();
    idt.reload();
    // gdt.loadTSS(&cpu_local.tss); // TODO: cause page fault

    // TODO: save cr3 or add a cr3 func to AddressSpace?
    vmm.switchPageTable(@intFromPtr(vmm.kernel_address_space.page_table) - vmm.hhdm_offset);

    // TODO threads + lapic

    log.info("processor {} is online", .{cpu_local.lapic_id});
    cpus_started += 1;

    if (!cpu_local.bsp) {
        arch.halt();
    }
}

fn initFeatures() void {
    // enable SSE/SSE2
    var cr0: u64 = arch.readRegister("cr0");
    cr0 &= ~@as(u64, (1 << 2));
    cr0 |= (1 << 1);
    arch.writeRegister("cr0", cr0);

    var cr4: u64 = arch.readRegister("cr4");
    cr4 |= (1 << 9);
    cr4 |= (1 << 10);
    arch.writeRegister("cr4", cr4);

    // init PAT (write-protect / write-combining)
    var pat_msr = arch.rdmsr(0x277);
    pat_msr &= 0xffffffff;
    pat_msr |= @as(u64, 0x0105) << 32;
    arch.wrmsr(0x277, pat_msr);

    // TODO
    // use cpuid
}
