const std = @import("std");
const limine = @import("limine");
const root = @import("root");
const arch = @import("arch.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const apic = @import("apic.zig");
const sched = @import("sched.zig");
const Thread = @import("proc.zig").Thread;
const SpinLock = @import("lock.zig").SpinLock;
const log = std.log.scoped(.cpu);

// TODO: use SYSENTER/SYSEXIT
// TODO: use FSGSBASE
// TODO: move asm to x86_64.zig?

pub const CpuLocal = struct {
    cpu_number: usize, // TODO: useless?
    // active: bool,
    // last_run_queue_index: u32,
    lapic_id: u32,
    lapic_freq: u64,
    tss: gdt.TSS,
    idle_thread: *Thread,
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

/// https://en.wikipedia.org/wiki/CPUID#EAX=1:_Processor_Info_and_Feature_Bits
const Feature = enum(u64) {
    // ecx
    sse3 = 1 << 0,
    pclmul = 1 << 1,
    dtes64 = 1 << 2,
    monitor = 1 << 3,
    ds_cpl = 1 << 4,
    vmx = 1 << 5,
    smx = 1 << 6,
    est = 1 << 7,
    tm2 = 1 << 8,
    ssse3 = 1 << 9,
    cxd = 1 << 10,
    sdbg = 1 << 11,
    fma = 1 << 12,
    cx16 = 1 << 13,
    xtpr = 1 << 14,
    pdcm = 1 << 15,
    pcid = 1 << 17,
    dca = 1 << 18,
    sse4_1 = 1 << 19,
    sse4_2 = 1 << 20,
    x2apic = 1 << 21,
    movbe = 1 << 22,
    popcnt = 1 << 23,
    tsc_deadline = 1 << 24,
    aes = 1 << 25,
    xsave = 1 << 26,
    osxsave = 1 << 27,
    avx = 1 << 28,
    f16c = 1 << 29,
    rdrand = 1 << 30,

    // edx
    fpu = 1 << 32,
    vme = 1 << 33,
    de = 1 << 34,
    pse = 1 << 35,
    tsc = 1 << 36,
    msr = 1 << 37,
    pae = 1 << 38,
    mce = 1 << 39,
    cx8 = 1 << 40,
    apic = 1 << 41,
    sep = 1 << 43,
    mtrr = 1 << 44,
    pge = 1 << 45,
    mca = 1 << 46,
    cmov = 1 << 47,
    pat = 1 << 48,
    pse36 = 1 << 49,
    psn = 1 << 50,
    clflush = 1 << 51,
    ds = 1 << 53,
    acpi = 1 << 54,
    mmx = 1 << 55,
    fxsr = 1 << 56,
    sse = 1 << 57,
    sse2 = 1 << 58,
    ss = 1 << 59,
    htt = 1 << 60,
    tm = 1 << 61,
    ia64 = 1 << 62,
    pbe = 1 << 63,
};

const page_size = std.mem.page_size;
const stack_size = 0x10000; // 64KiB

pub var bsp_lapic_id: u32 = undefined; // bootstrap processor lapic id
pub var cpus: []CpuLocal = undefined;
var cpus_started: usize = 0;

// TODO
// pub var sysenter: bool = false;
pub var fpu_storage_size: usize = 0;
pub var fpu_save: *const fn (*idt.Context) void = undefined;
pub var fpu_restore: *const fn (*idt.Context) void = undefined;

var lapic_lock: SpinLock = .{};

pub fn init() void {
    const smp = root.smp_request.response.?;
    bsp_lapic_id = smp.bsp_lapic_id;
    cpus = root.allocator.alloc(CpuLocal, smp.cpu_count) catch unreachable;
    @memset(std.mem.sliceAsBytes(cpus), 0); // TODO: useless?
    log.info("{} processors detected", .{cpus.len});

    // TODO: lapic irq handler

    for (smp.cpus(), cpus, 0..) |cpu, *cpu_local, i| {
        cpu.extra_argument = @intFromPtr(cpu_local);
        cpu_local.cpu_number = i;

        if (cpu.lapic_id != bsp_lapic_id) {
            cpu.goto_address = trampoline;
        } else {
            cpu_local.lapic_id = cpu.lapic_id;
            gdt.loadTSS(&cpu_local.tss);

            const idle_thread = root.allocator.create(Thread) catch unreachable;
            idle_thread.self = idle_thread;
            idle_thread.this_cpu = cpu_local;
            idle_thread.process = sched.kernel_process;
            cpu_local.idle_thread = idle_thread;
            setGsBase(@intFromPtr(idle_thread));

            // TODO: is common_int_stack correct?
            const common_int_stack_phys = pmm.alloc(@divExact(stack_size, page_size), true) orelse unreachable;
            const common_int_stack = common_int_stack_phys + stack_size + vmm.hhdm_offset;
            cpu_local.tss.rsp[0] = common_int_stack;

            // const sched_stack_phys = pmm.alloc(@divExact(stack_size, page_size), true) orelse unreachable;
            // const sched_stack = sched_stack_phys + stack_size + vmm.hhdm_offset;
            // cpu_local.tss.ist[1] = sched_stack;

            initFeatures(true);

            // TODO:
            // kernel_print("cpu: SYSENTER not present! Using #UD\n");
            // idt_register_handler(0x06, syscall_ud_entry, 0x8e);
            // idt_set_ist(0x6, 3); // #UD uses IST 3

            lapic_lock.lock();
            apic.init();
            lapic_lock.unlock();

            arch.enableInterrupts();

            log.info("bootstrap processor is online", .{});
            cpus_started += 1;
            // TODO
            // trampoline(cpu);
        }
    }

    while (cpus_started != cpus.len) {
        std.atomic.spinLoopHint();
    }
}

pub fn thisCpu() *CpuLocal {
    const thread = sched.currentThread();
    // TODO: panic when calling this function with interrupts on or scheduling enabled
    return thread.this_cpu;
}

fn trampoline(smp_info: *limine.SmpInfo) callconv(.C) noreturn {
    const cpu_local: *CpuLocal = @ptrFromInt(smp_info.extra_argument);
    cpu_local.lapic_id = smp_info.lapic_id;

    gdt.reload();
    idt.reload();
    gdt.loadTSS(&cpu_local.tss);

    vmm.switchPageTable(vmm.kernel_address_space.page_table);

    const idle_thread = root.allocator.create(Thread) catch unreachable;
    idle_thread.self = idle_thread;
    idle_thread.this_cpu = cpu_local;
    idle_thread.process = sched.kernel_process;
    cpu_local.idle_thread = idle_thread;
    setGsBase(@intFromPtr(idle_thread));

    const common_int_stack_phys = pmm.alloc(@divExact(stack_size, page_size), true) orelse unreachable;
    const common_int_stack = common_int_stack_phys + stack_size + vmm.hhdm_offset;
    cpu_local.tss.rsp[0] = common_int_stack;

    // TODO
    // const sched_stack_phys = pmm.alloc(@divExact(stack_size, page_size), true) orelse unreachable;
    // const sched_stack = sched_stack_phys + stack_size + vmm.hhdm_offset;
    // cpu_local.tss.ist[1] = sched_stack;

    initFeatures(false);

    lapic_lock.lock();
    apic.init();
    lapic_lock.unlock();

    arch.enableInterrupts();

    log.info("processor {} is online", .{cpu_local.lapic_id});
    cpus_started += 1;

    arch.halt();
}

inline fn hasFeature(features: u64, feat: Feature) bool {
    if (features & @intFromEnum(feat) != 0) {
        std.log.debug("has feature {}", .{feat});
    }
    return features & @intFromEnum(feat) != 0;
}

fn initFeatures(bsp: bool) void {
    const regs = arch.cpuid(1, 0);
    const features: u64 = @as(u64, regs.edx) << 32 | regs.ecx;

    // TODO: check if the SSE, SSE and PAT are available

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
    var pat = arch.rdmsr(0x277);
    pat &= 0xffffffff;
    pat |= @as(u64, 0x0105) << 32;
    arch.wrmsr(0x277, pat);

    // TODO
    if (false) { //hasFeature(features, .xsave)) {
        if (bsp) log.info("xsave supported", .{});

        // enable xsave and x{get, set}bv
        cr4 = arch.readRegister("cr4");
        cr4 |= @as(u64, 1) << 18;
        arch.writeRegister("cr4", cr4);

        var xcr0: u64 = 0;
        if (bsp) log.info("saving x87 state using xsave", .{});
        xcr0 |= @as(u64, 1) << 0;
        if (bsp) log.info("saving sse state using xsave", .{});
        xcr0 |= @as(u64, 1) << 1;

        if (hasFeature(features, .avx)) {
            if (bsp) log.info("saving avx state using xsave", .{});
            xcr0 |= @as(u64, 1) << 2;
        }

        // TODO
        // if (cpuid(7, 0, &eax, &ebx, &ecx, &edx) && (ebx & CPUID_AVX512)) {
        //     if (cpu_local->bsp) {
        //         kernel_print("fpu: Saving AVX-512 state using xsave\n");
        //     }
        //     xcr0 |= (uint64_t)1 << 5;
        //     xcr0 |= (uint64_t)1 << 6;
        //     xcr0 |= (uint64_t)1 << 7;
        // }

        // TODO
        // arch.wrxcr(0, xcr0);

        // TODO
        // test cpuid with 0xd <- new ecx

        // fpu_storage_size = regs.ecx;
        // fpu_save = xsave;
        // fpu_restore = xrstor;
    } else {
        if (bsp) log.info("use legacy fxsave", .{});
        fpu_storage_size = 512;
        // TODO: can't have inline func as ptr
        // fpu_save = fxsave;
        // fpu_restore = fxrstor;
    }
}

inline fn setGsBase(addr: u64) void {
    arch.wrmsr(0xc0000101, addr);
}

inline fn xsave(ctx: *idt.Context) void {
    asm volatile (
        \\xsave [%ctx]
        :
        : [ctx] "r" (ctx),
          [_] "a" (0xffffffff),
          [_] "d" (0xffffffff),
        : "memory"
    );
}

inline fn xrstor(ctx: *idt.Context) void {
    asm volatile (
        \\xrstor %[ctx]
        :
        : [ctx] "r" (ctx),
          [_] "a" (0xffffffff),
          [_] "d" (0xffffffff),
        : "memory"
    );
}

inline fn fxsave(ctx: *idt.Context) void {
    asm volatile (
        \\fxsave %[ctx]
        :
        : [ctx] "r" (ctx),
        : "memory"
    );
}

inline fn fxrstor(ctx: *idt.Context) void {
    asm volatile (
        \\fxrstor %[ctx]
        :
        : [ctx] "r" (ctx),
        : "memory"
    );
}
