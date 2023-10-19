const std = @import("std");
const root = @import("root");
const arch = @import("arch.zig");
const idt = arch.idt;
const apic = @import("apic.zig");
const rand = @import("rand.zig");
const smp = @import("smp.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const SpinLock = @import("SpinLock.zig");
const log = std.log.scoped(.sched);
const page_size = std.mem.page_size;

// TODO: if a process create a lot of thread it can suck all the cpu
//       -> check the process of the chosen thread smh to fix that
// TODO: use a (red-black) tree instead of an arraylist

pub const Process = struct {
    pid: usize,
    name: [127:0]u8,
    parent: ?*Process, // use ppid ?
    addr_space: *vmm.AddressSpace,
    // mmap_anon_base: usize,
    // thread_stack_top: usize,
    threads: std.ArrayListUnmanaged(*Thread),
    children: std.ArrayListUnmanaged(*Process),
    // child_events
    // event: ev.Event

    // cwd: // TODO
    // fds_lock: SpinLock,
    // umask: u32,
    // fds

    // running_time: usize,

    pub fn init(parent: ?*Process, addr_space: ?*vmm.AddressSpace) !*Process {
        const proc = try root.allocator.create(Process);
        errdefer root.allocator.destroy(proc);

        try processes.append(root.allocator, proc);
        errdefer _ = processes.popOrNull(); // TODO: or just assume push to parent won't fail :D
        proc.pid = processes.items.len - 1;
        proc.parent = parent;
        proc.threads = .{};
        proc.children = .{};

        if (parent) |p| {
            @memcpy(&proc.name, &p.name);
            // proc.addr_space = try old_proc.addr_space.fork();
            // proc.thread_stack_top = old_proc.thread_stack_top;
            // proc.mmap_anon_base = old_proc.mmap_anon_base;
            // proc.cwd = old_proc.cwd;
            // proc.umask = old_proc.umask;

            try p.children.append(root.allocator, proc);
            // try old_proc.child_events.append(root.allocator, &proc.event);
        } else {
            @memset(&proc.name, 0);
            proc.addr_space = addr_space.?;
            // proc.thread_stack_top = 0x70000000000;
            // proc.mmap_anon_base = 0x80000000000;
            // proc.cwd = vfs_root;
            // proc.umask = S_IWGRP | S_IWOTH;
        }

        return proc;
    }
};

pub const Thread = struct {
    self: *Thread, // TODO
    errno: usize, // TODO

    tid: usize,
    lock: SpinLock = .{}, // TODO?
    cpu: *smp.CpuLocal,
    process: *Process,
    ctx: arch.Context,

    tickets: usize,

    scheduling_off: bool, // TODO?
    enqueued: bool, // TODO: useless?
    // enqueued_by_signal: bool,
    timeslice: u32, // in microseconds
    yield_await: SpinLock = .{},
    gs_base: u64,
    fs_base: u64,
    cr3: u64,
    fpu_storage: u64,
    stacks: std.ArrayListUnmanaged(u64),
    pf_stack: u64,
    kernel_stack: u64,

    // which_event: usize,
    // attached_events_i: usize,
    // attached_events: [ev.max_event]*ev.Event,

    // running_time: usize,

    pub const stack_size = 1024 * 1024; // 1MiB
    pub const stack_pages = stack_size / page_size;

    // TODO: improve
    //       use root.allocator instead of pmm.alloc?
    pub fn initKernel(func: *const anyopaque, arg: ?*anyopaque, tickets: usize) !*Thread {
        const thread = try root.allocator.create(Thread);
        errdefer root.allocator.destroy(thread);
        @memset(std.mem.asBytes(thread), 0);

        thread.self = thread;
        thread.errno = 0;

        thread.tickets = tickets;

        // thread.tid = undefined; // normal
        thread.lock = .{};
        thread.yield_await = .{};
        thread.stacks = .{};

        const stack_phys = pmm.alloc(stack_pages, true) orelse {
            root.allocator.destroy(thread);
            return error.OutOfMemory;
        };
        try thread.stacks.append(root.allocator, stack_phys);
        const stack = stack_phys + stack_size + vmm.hhdm_offset;

        thread.ctx.cs = 0x08;
        thread.ctx.ds = 0x10;
        thread.ctx.es = 0x10;
        thread.ctx.ss = 0x10;
        thread.ctx.rflags = @bitCast(arch.Rflags{ .IF = 1 });
        thread.ctx.rip = @intFromPtr(func);
        thread.ctx.rdi = @intFromPtr(arg);
        thread.ctx.rsp = stack;

        thread.cr3 = kernel_process.addr_space.cr3();
        thread.gs_base = @intFromPtr(thread);

        thread.process = kernel_process;
        thread.timeslice = 1000;
        // TODO: calculate this once and store it in arch.cpu.fpu_storage_pages
        const pages = std.math.divCeil(u64, arch.cpu.fpu_storage_size, page_size) catch unreachable;
        const fpu_storage_phys = pmm.alloc(pages, true) orelse {
            pmm.free(stack_phys, stack_pages);
            root.allocator.destroy(thread);
            return error.OutOfMemory;
        };
        thread.fpu_storage = fpu_storage_phys + vmm.hhdm_offset;

        // kernel_process.threads.append(root.allocator, thread);

        std.debug.assert(@intFromPtr(thread) == @intFromPtr(&thread.self));

        return thread;
    }

    // TODO: idk if this should be in kernel, it is pthread
    pub fn initUser() !*Thread {
        @compileError("TODO");
    }

    // TODO
    pub fn deinit(self: *Thread) void {
        for (self.stacks.items) |stack| {
            pmm.free(stack, stack_pages);
        }
        // TODO: calculate this once and store it in arch.cpu.fpu_storage_pages
        const pages = std.math.divCeil(u64, arch.cpu.fpu_storage_size, page_size) catch unreachable;
        pmm.free(self.fpu_storage - vmm.hhdm_offset, pages);
        root.allocator.destroy(self);
    }
};

pub var kernel_process: *Process = undefined;
pub var processes: std.ArrayListUnmanaged(*Process) = .{};
var sched_vector: u8 = undefined;
var running_threads: std.ArrayListUnmanaged(*Thread) = .{};
var sched_lock: SpinLock = .{};
var total_tickets: usize = 0;
var pcg: rand.Pcg = undefined;
const random: rand.Random = pcg.random();

pub fn init() void {
    pcg = rand.Pcg.init(rand.getSeedSlow());
    kernel_process = Process.init(null, vmm.kaddr_space) catch unreachable;
    sched_vector = idt.allocVector();
    log.info("scheduler interrupt vector: 0x{x}", .{sched_vector});
    idt.registerHandler(sched_vector, schedHandler);
    // idt.setIST(sched_vector, 1); // TODO
}

// TODO: save cpu in gs not thread
pub inline fn currentThread() *Thread {
    return asm volatile (
        \\mov %%gs:0x0, %[thr]
        : [thr] "=r" (-> *Thread),
    );
}

// O(n)
fn nextThread() ?*Thread {
    const ticket = random.uintLessThan(usize, total_tickets + 1);
    var sum: usize = 0;

    sched_lock.lock();
    defer sched_lock.unlock();

    for (running_threads.items) |thr| {
        sum += thr.tickets;
        if (sum > ticket) {
            return thr;
        }
    }
    return null;
}

// O(1)
pub fn enqueue(thread: *Thread) !void {
    if (thread.enqueued) return;

    sched_lock.lock();
    errdefer sched_lock.unlock();

    try running_threads.append(root.allocator, thread);
    total_tickets += thread.tickets;
    thread.enqueued = true;
    log.info("enqueued thread: {*}", .{thread});

    sched_lock.unlock();

    for (smp.cpus) |cpu| {
        if (!cpu.active) {
            apic.sendIPI(cpu.lapic_id, sched_vector);
            break;
        }
    }
}

// O(n)
pub fn dequeue(thread: *Thread) void {
    if (!thread.enqueued) return;

    sched_lock.lock();
    defer sched_lock.unlock();

    for (running_threads.items, 0..) |thr, i| {
        if (thr == thread) {
            _ = running_threads.swapRemove(i);
            total_tickets -= thread.tickets;
            thread.enqueued = false;
            log.info("dequeued thread: {*}", .{thread});
            return;
        }
    }
    log.warn("trying to dequeue unknown thread: {*}", .{thread});
}

pub fn die() noreturn {
    arch.disableInterrupts();
    dequeue(currentThread());
    // TODO: deinit current thread
    yield(false);
    unreachable;
}

fn schedHandler(ctx: *arch.Context) void {
    apic.timerStop();

    var current_thread = currentThread();
    std.debug.assert(@intFromPtr(current_thread) != 0); // TODO

    // TODO
    if (current_thread.scheduling_off) {
        apic.eoi();
        apic.timerOneShot(current_thread.timeslice, sched_vector);
        return;
    }

    const cpu = smp.thisCpu(); // TODO: current_thread.cpu
    cpu.active = true;
    const next_thread = nextThread();

    if (current_thread != cpu.idle) {
        current_thread.yield_await.unlock();

        if (next_thread == null and current_thread.enqueued) {
            apic.eoi();
            apic.timerOneShot(current_thread.timeslice, sched_vector);
            return;
        }

        current_thread.ctx = ctx.*;

        if (arch.arch == .x86_64) {
            current_thread.gs_base = arch.getKernelGsBase();
            current_thread.fs_base = arch.getFsBase();
            current_thread.cr3 = arch.readRegister("cr3");
            arch.cpu.fpuSave(current_thread.fpu_storage);
        }

        // TODO
        // current_thread.cpu = null;
        current_thread.lock.unlock();
    }

    if (next_thread == null) {
        apic.eoi();
        if (arch.arch == .x86_64) {
            arch.setGsBase(@intFromPtr(cpu.idle));
            arch.setKernelGsBase(@intFromPtr(cpu.idle));
        }
        cpu.active = false;
        vmm.switchPageTable(vmm.kaddr_space.cr3());
        wait();
    }

    current_thread = next_thread.?;

    if (arch.arch == .x86_64) {
        arch.setGsBase(@intFromPtr(current_thread));
        if (current_thread.ctx.cs == 0x08) { // 0x08 = kernel cs
            arch.setKernelGsBase(@intFromPtr(current_thread));
        } else {
            arch.setKernelGsBase(current_thread.gs_base);
        }
        arch.setFsBase(current_thread.fs_base);

        // TODO: SYSENTER
        // if (sysenter) {
        //     arch.wrmsr(0x175, @intFromPtr(current_thread.kernel_stack));
        // } else {
        //     cpu.tss.ist[3] = @intFromPtr(current_thread.kernel_stack);
        // }

        // TODO: set page fault stack
        // cpu.tss.ist[2] = current_thread.pf_stack;

        if (arch.readRegister("cr3") != current_thread.cr3) {
            arch.writeRegister("cr3", current_thread.cr3);
        }

        arch.cpu.fpuRestore(current_thread.fpu_storage);
    }

    current_thread.cpu = cpu;

    apic.eoi();
    apic.timerOneShot(current_thread.timeslice, sched_vector);
    contextSwitch(&current_thread.ctx);
}

pub fn wait() noreturn {
    arch.disableInterrupts();
    apic.timerOneShot(1000, sched_vector);
    arch.enableInterrupts();
    arch.halt();
}

pub fn yield(save_ctx: bool) void {
    arch.disableInterrupts();
    apic.timerStop();

    const thread = currentThread();
    const cpu = smp.thisCpu(); // TODO: thread.cpu

    if (save_ctx) {
        thread.yield_await.lock();
    } else {
        arch.setGsBase(@intFromPtr(cpu.idle));
        arch.setKernelGsBase(@intFromPtr(cpu.idle));
    }

    apic.sendIPI(cpu.lapic_id, sched_vector);
    arch.enableInterrupts();

    if (save_ctx) {
        thread.yield_await.lock();
        thread.yield_await.unlock();
    } else {
        arch.halt();
    }
}

fn contextSwitch(ctx: *arch.Context) noreturn {
    asm volatile (
        \\mov %[ctx], %%rsp
        \\pop %%rax
        \\mov %%ax, %%ds
        \\pop %%rax
        \\mov %%ax, %%es
        \\pop %%rax
        \\pop %%rbx
        \\pop %%rcx
        \\pop %%rdx
        \\pop %%rsi
        \\pop %%rdi
        \\pop %%rbp
        \\pop %%r8
        \\pop %%r9
        \\pop %%r10
        \\pop %%r11
        \\pop %%r12
        \\pop %%r13
        \\pop %%r14
        \\pop %%r15
        // TODO: check if user?
        \\swapgs
        \\add $16, %%rsp
        \\iretq
        :
        : [ctx] "rm" (ctx),
        : "memory"
    );
    unreachable;
}
