const std = @import("std");
const limine = @import("limine");
const root = @import("root");
const arch = @import("arch.zig");
const gdt = arch.gdt;
const idt = arch.idt;
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const apic = @import("apic.zig");
const sched = @import("sched.zig");
const Thread = @import("proc.zig").Thread;
const SpinLock = @import("lock.zig").SpinLock;
const log = std.log.scoped(.smp);

// TODO: use SYSENTER/SYSEXIT
// TODO: use FSGSBASE
// TODO: move asm and x86 specific stuff to x86_64.zig

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

const page_size = std.mem.page_size;
const stack_size = 0x10000; // 64KiB

pub var bsp_lapic_id: u32 = undefined; // bootstrap processor lapic id
pub var cpus: []CpuLocal = undefined;
var cpus_started: usize = 0;

// TODO
// pub var sysenter = false;

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
            arch.setGsBase(@intFromPtr(idle_thread));

            // TODO: is common_int_stack correct?
            const common_int_stack_phys = pmm.alloc(@divExact(stack_size, page_size), true) orelse unreachable;
            const common_int_stack = common_int_stack_phys + stack_size + vmm.hhdm_offset;
            cpu_local.tss.rsp[0] = common_int_stack;

            // const sched_stack_phys = pmm.alloc(@divExact(stack_size, page_size), true) orelse unreachable;
            // const sched_stack = sched_stack_phys + stack_size + vmm.hhdm_offset;
            // cpu_local.tss.ist[1] = sched_stack;

            arch.cpu.initFeatures(true);

            // TODO:
            // kernel_print("cpu: SYSENTER not present! Using #UD\n");
            // idt_register_handler(0x06, syscall_ud_entry, 0x8e);
            // idt_set_ist(0x6, 3); // #UD uses IST 3

            lapic_lock.lock();
            apic.init();
            lapic_lock.unlock();

            arch.enableInterrupts();

            log.info("bootstrap processor is online", .{});
            _ = @atomicRmw(usize, &cpus_started, .Add, 1, .Release);
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
    arch.setGsBase(@intFromPtr(idle_thread));

    const common_int_stack_phys = pmm.alloc(@divExact(stack_size, page_size), true) orelse unreachable;
    const common_int_stack = common_int_stack_phys + stack_size + vmm.hhdm_offset;
    cpu_local.tss.rsp[0] = common_int_stack;

    // TODO
    // const sched_stack_phys = pmm.alloc(@divExact(stack_size, page_size), true) orelse unreachable;
    // const sched_stack = sched_stack_phys + stack_size + vmm.hhdm_offset;
    // cpu_local.tss.ist[1] = sched_stack;

    arch.cpu.initFeatures(false);

    lapic_lock.lock();
    apic.init();
    lapic_lock.unlock();

    arch.enableInterrupts();

    log.info("processor {} is online", .{cpu_local.lapic_id});
    _ = @atomicRmw(usize, &cpus_started, .Add, 1, .AcqRel);

    arch.halt();
}
