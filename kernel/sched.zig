const std = @import("std");
const root = @import("root");
const ubik = @import("ubik");
const arch = @import("arch.zig");
const gdt = arch.gdt;
const idt = arch.idt;
const apic = arch.apic;
const rand = @import("rand.zig");
const smp = @import("smp.zig");
const pmm = root.pmm;
const vmm = root.vmm;
const vfs = @import("vfs.zig");
const Event = @import("event.zig").Event;
const SpinLock = root.SpinLock;

// TODO: merge Process and Thread

// TODO: if a process create a lot of thread it can suck all the cpu
//       -> check the process of the chosen thread smh to fix that

pub const Process = struct {
    id: ubik.pid_t,
    name: [127:0]u8,
    parent: ?*Process,
    addr_space: *vmm.AddressSpace,
    mmap_anon_base: usize, // TODO
    thread_stack_top: usize, // TODO
    threads: std.ArrayListUnmanaged(*Thread),
    children: std.ArrayListUnmanaged(*Process),
    child_events: std.ArrayListUnmanaged(*Event),
    event: Event,
    // running_time: usize, // TODO
    // status: enum { running, ready, blocked (io) }, // TODO: in threads? + atomic (replace lock)
    user: ubik.uid_t,
    group: ubik.gid_t,

    // I/O context
    cwd: *vfs.Node,
    umask: ubik.mode_t,
    fds_lock: SpinLock,
    fds: std.ArrayListUnmanaged(*vfs.FileDescriptor),

    var next_pid = std.atomic.Value(ubik.pid_t).init(0);

    // TODO: more errdefer
    pub fn init(parent: ?*Process, addr_space: ?*vmm.AddressSpace) !*Process {
        const process = try root.allocator.create(Process);
        errdefer root.allocator.destroy(process);

        process.parent = parent;
        process.threads = .{};
        process.children = .{};
        process.child_events = .{};

        if (parent) |p| {
            @memcpy(&process.name, &p.name);
            process.addr_space = try p.addr_space.fork();
            process.thread_stack_top = p.thread_stack_top;
            process.mmap_anon_base = p.mmap_anon_base;
            process.cwd = p.cwd;
            process.umask = p.umask;

            try p.children.append(root.allocator, process);
            try p.child_events.append(root.allocator, &process.event);
        } else {
            @memset(&process.name, 0);
            process.addr_space = addr_space.?;
            // TODO
            process.thread_stack_top = 0x0700_0000_0000;
            process.mmap_anon_base = 0x0800_0000_0000;
            // process.cwd = vfs.tree.root.?;
            process.umask = ubik.S.IWGRP | ubik.S.IWOTH;
        }

        try processes.append(root.allocator, process);
        process.id = next_pid.fetchAdd(1, .release);

        return process;
    }

    pub fn deinit(self: *Process) void {
        // TODO: items of each arraylist + addr_space + parent + processes

        self.threads.deinit(root.allocator);
        self.children.deinit(root.allocator);
        self.child_events.deinit(root.allocator);
        self.fds.deinit(root.allocator);
        root.allocator.destroy(self);
    }
};

pub const Thread = struct {
    tid: usize,
    lock: SpinLock = .{},
    process: *Process,
    ctx: arch.Context,

    tickets: usize,

    enqueued: bool,
    run_prev: ?*Thread = null,
    run_next: ?*Thread = null,
    // enqueued_by_signal: bool, // TODO: for events
    reschedule_pending: bool = false,
    dying: bool = false,
    // gs_base
    fs_base: u64,
    cr3: u64,
    fpu_storage: u64,
    stacks: std.ArrayListUnmanaged(u64) = .{},
    pf_stack: u64,
    kernel_stack: u64,

    which_event: usize,
    waiting_event: bool = false,

    // running_time: usize, // TODO

    pub const stack_size = 8 * 1024 * 1024; // 8MiB
    pub const stack_pages = stack_size / std.mem.page_size;

    // TODO: merge initUser and initKernel?
    pub fn initKernel(func: *const anyopaque, arg: ?*anyopaque, tickets: usize) !*Thread {
        if (tickets == 0) return error.InvalidTickets;
        const thread = try root.allocator.create(Thread);
        errdefer root.allocator.destroy(thread);

        thread.* = .{
            .tid = undefined,
            .process = kernel_process,
            .ctx = std.mem.zeroes(arch.Context),
            .tickets = tickets,
            .enqueued = false,
            .fs_base = 0,
            .cr3 = kernel_process.addr_space.cr3(),
            .fpu_storage = undefined, // defined after
            .pf_stack = undefined,
            .kernel_stack = undefined,
            .which_event = undefined,
        };

        errdefer {
            for (thread.stacks.items) |stack| pmm.free(stack, stack_pages);
            thread.stacks.deinit(root.allocator);
        }

        const fpu_storage = try root.allocator.alignedAlloc(u8, arch.cpu.fpu_storage_alignment, arch.cpu.fpu_storage_size);
        errdefer root.allocator.free(fpu_storage);
        @memset(fpu_storage, 0);
        // The legacy FXSAVE region also supplies defaults when XSAVE is unavailable.
        std.mem.writeInt(u16, fpu_storage[0..2], 0x037f, .little);
        std.mem.writeInt(u32, fpu_storage[24..28], 0x1f80, .little);
        thread.fpu_storage = @intFromPtr(fpu_storage.ptr);

        thread.ctx.cs = gdt.kernel_code;
        thread.ctx.ds = gdt.kernel_data;
        thread.ctx.es = gdt.kernel_data;
        thread.ctx.ss = gdt.kernel_data;
        thread.ctx.rflags = @bitCast(arch.RFlags{ .IF = 1 });
        thread.ctx.rip = @intFromPtr(&kernelEntry);
        thread.ctx.rdi = @intFromPtr(func);
        thread.ctx.rsi = @intFromPtr(arg);
        thread.kernel_stack = try thread.allocateStack();
        thread.pf_stack = try thread.allocateStack();
        // IRET enters a function as if CALL had pushed an eight-byte return address.
        thread.ctx.rsp = thread.kernel_stack - @sizeOf(u64);
        @as(*u64, @ptrFromInt(thread.ctx.rsp)).* = 0;

        // TODO
        // kernel_process.threads.append(root.allocator, thread);

        return thread;
    }

    // TODO: idk if this should be in kernel or userspace
    pub fn initUser(
        process: *Process,
        func: *const anyopaque,
        args: ?*anyopaque,
        stack_ptr: ?*anyopaque,
        argv: [][*:0]u8,
        environ: [][*:0]u8,
        tickets: usize,
    ) !*Thread {
        const thread = try root.allocator.create(Thread);
        errdefer thread.deinit();
        @memset(std.mem.asBytes(thread), 0);

        thread.process = process;
        thread.tickets = tickets;
        thread.lock = .{};
        thread.enqueued = false;
        thread.reschedule_pending = false;
        thread.dying = false;
        thread.stacks = .{};

        // TODO: ugly + save in threads.stacks so it's easily freed on deinit?
        var stack: u64 = undefined;
        var stack_vma: u64 = undefined;
        if (stack_ptr) |sp| {
            stack = @intFromPtr(sp);
            stack_vma = @intFromPtr(sp);
        } else {
            const stack_phys = pmm.alloc(stack_pages, true) orelse return error.OutOfMemory;
            errdefer pmm.free(stack_phys, stack_pages);

            stack = stack_phys + stack_size + vmm.hhdm_offset;
            stack_vma = process.thread_stack_top;
            try process.addr_space.mmapRange(
                process.thread_stack_top - stack_size,
                stack_phys,
                stack_size,
                ubik.PROT.READ | ubik.PROT.WRITE,
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            );
            process.thread_stack_top -= stack_size - std.mem.page_size;
        }

        thread.kernel_stack = blk: {
            const stack_phys = pmm.alloc(stack_pages, true) orelse return error.OutOfMemory;
            errdefer pmm.free(stack_phys, stack_pages);
            try thread.stacks.append(root.allocator, stack_phys);
            break :blk stack_phys + stack_size + vmm.hhdm_offset;
        };

        thread.pf_stack = blk: {
            const stack_phys = pmm.alloc(stack_pages, true) orelse return error.OutOfMemory;
            errdefer pmm.free(stack_phys, stack_pages);
            try thread.stacks.append(root.allocator, stack_phys);
            break :blk stack_phys + stack_size + vmm.hhdm_offset;
        };

        thread.ctx.cs = gdt.user_code;
        thread.ctx.ds = gdt.user_data;
        thread.ctx.es = gdt.user_data;
        thread.ctx.ss = gdt.user_data;
        thread.ctx.rflags = @bitCast(arch.RFlags{ .IF = 1 });
        thread.ctx.rip = @intFromPtr(func);
        thread.ctx.rdi = @intFromPtr(args);
        thread.ctx.rsp = stack_vma;
        thread.cr3 = process.addr_space.cr3();

        // const fpu_storage_phys = pmm.alloc(arch.cpu.fpu_storage_pages, true) orelse return error.OutOfMemory;
        // thread.fpu_storage = fpu_storage_phys + vmm.hhdm_offset;

        // TODO: set up FPU control word and MXCSR based on SysV ABI
        arch.cpu.fpuRestore(thread.fpu_storage);
        const default_fcw: u16 = 0b1100111111;
        asm volatile (
            \\fldcw %[fcw]
            :
            : [fcw] "m" (default_fcw),
            : "memory"
        );
        const default_mxcsr: u32 = 0b1111110000000;
        asm volatile (
            \\ldmxcsr %[mxcsr]
            :
            : [mxcsr] "m" (default_mxcsr),
            : "memory"
        );
        arch.cpu.fpuSave(thread.fpu_storage);

        thread.tid = process.threads.items.len; // TODO?

        if (process.threads.items.len == 0) {
            const stack_top = stack;
            _ = stack_top;

            for (environ) |entry| {
                const len = std.mem.len(entry);
                stack = stack - len - 1;
                @memcpy(@as(u8, @ptrFromInt(stack)), entry[0..len]);
            }

            for (argv) |arg| {
                const len = std.mem.len(arg);
                stack = stack - len - 1;
                @memcpy(@as(u8, @ptrFromInt(stack)), arg[0..len]);
            }

            // TODO
            stack = std.mem.alignBackward(stack, 16);
            if ((argv.len + environ.len + 1) & 1 != 0) {
                stack -= @sizeOf(u64);
            }

            // TODO: elf
            // TODO: stuff
        }

        try process.threads.append(root.allocator, thread);

        @compileError("not finished yet");
        // return thread;
    }

    fn allocateStack(self: *Thread) !u64 {
        const physical = pmm.alloc(stack_pages, true) orelse return error.OutOfMemory;
        errdefer pmm.free(physical, stack_pages);
        try self.stacks.append(root.allocator, physical);
        return physical + stack_size + vmm.hhdm_offset;
    }

    fn kernelEntry(entry: *const fn (?*anyopaque) callconv(.SysV) void, arg: ?*anyopaque) callconv(.SysV) noreturn {
        entry(arg);
        die();
    }

    pub fn deinit(self: *Thread) void {
        for (self.stacks.items) |stack| {
            pmm.free(stack, stack_pages);
        }
        self.stacks.deinit(root.allocator);
        const fpu_storage: [*]align(arch.cpu.fpu_storage_alignment) u8 = @ptrFromInt(self.fpu_storage);
        root.allocator.free(fpu_storage[0..arch.cpu.fpu_storage_size]);
        root.allocator.destroy(self);
    }
};

/// reschedule every 50ms
const quantum = 50_000;

pub var kernel_process: *Process = undefined;
pub var processes: std.ArrayListUnmanaged(*Process) = .{}; // TODO: hashmap with pid?
// Intrusive links avoid allocation (and allocator lock inversion) under sched_lock.
var running_threads: ?*Thread = null;

var total_tickets: usize = 0;

var sched_vector: u8 = undefined;
var sched_lock: SpinLock = .{};
var pcg: rand.Pcg = undefined;

pub fn init() void {
    pcg = rand.Pcg.init(rand.getSeedSlow());
    kernel_process = Process.init(null, vmm.kaddr_space) catch unreachable;
    sched_vector = idt.allocVector();
    idt.registerHandler(sched_vector, schedHandler);
    idt.setIST(sched_vector, 1);
}

pub inline fn currentThread() *Thread {
    return smp.thisCpu().current_thread.?;
}

pub inline fn currentProcess() *Process {
    return currentThread().process;
}

fn nextThread() ?*Thread {
    sched_lock.lock();
    defer sched_lock.unlock();
    if (total_tickets == 0) return null;

    const ticket = pcg.random().uintLessThan(usize, total_tickets);
    var sum: usize = 0;
    var cursor = running_threads;
    while (cursor) |thread| : (cursor = thread.run_next) {
        sum += thread.tickets;
        if (ticket < sum) {
            // A running winner cannot migrate until its outgoing context is saved.
            // Walk the queue once so a busy winner cannot hide runnable work.
            var candidate = thread;
            while (true) {
                if (candidate.lock.tryLock()) return candidate;
                candidate = candidate.run_next orelse running_threads.?;
                if (candidate == thread) return null;
            }
        }
    }
    unreachable;
}

pub fn enqueue(thread: *Thread) !void {
    const interrupt_state = arch.toggleInterrupts(false);
    defer _ = arch.toggleInterrupts(interrupt_state);
    sched_lock.lock();
    enqueueLocked(thread) catch |err| {
        sched_lock.unlock();
        return err;
    };
    sched_lock.unlock();
    notifyRunnable();
}

fn enqueueLocked(thread: *Thread) !void {
    if (thread.dying) return error.ThreadExiting;
    if (thread.enqueued) return;
    if (thread.tickets == 0) return error.InvalidTickets;
    const tickets = try std.math.add(usize, total_tickets, thread.tickets);
    thread.run_prev = null;
    thread.run_next = running_threads;
    if (running_threads) |head| head.run_prev = thread;
    running_threads = thread;
    total_tickets = tickets;
    thread.enqueued = true;
}

fn notifyRunnable() void {
    // Do not race another CPU's current_thread just to choose an idle target.
    apic.sendIPI(undefined, .{ .vector = sched_vector, .destination_shorthand = .all_including_self });
}

pub fn dequeue(thread: *Thread) void {
    const interrupt_state = arch.toggleInterrupts(false);
    defer _ = arch.toggleInterrupts(interrupt_state);
    sched_lock.lock();
    defer sched_lock.unlock();
    dequeueLocked(thread);
}

fn dequeueLocked(thread: *Thread) void {
    if (!thread.enqueued) return;
    if (thread.run_prev) |previous| {
        previous.run_next = thread.run_next;
    } else {
        running_threads = thread.run_next;
    }
    if (thread.run_next) |next| next.run_prev = thread.run_prev;
    total_tickets -= thread.tickets;
    thread.enqueued = false;
    thread.run_prev = null;
    thread.run_next = null;
}

fn isEnqueued(thread: *Thread) bool {
    sched_lock.lock();
    defer sched_lock.unlock();
    return thread.enqueued;
}

pub fn die() noreturn {
    arch.disableInterrupts();
    const thread = currentThread();
    sched_lock.lock();
    thread.dying = true;
    dequeueLocked(thread);
    sched_lock.unlock();
    // The handler owns a per-CPU IST stack; only it may reclaim this stack.
    yield();
    unreachable;
}

fn schedHandler(ctx: *arch.Context) callconv(.SysV) void {
    apic.timerStop();

    const cpu = smp.thisCpu();

    // if (cpu.scheduling_disabled) {
    //     apic.eoi();
    //     apic.timerOneShot(quantum, sched_vector);
    //     return;
    // }

    const maybe_next_thread = nextThread();

    if (cpu.current_thread) |current_thread| {
        sched_lock.lock();
        current_thread.reschedule_pending = false;
        const dying = current_thread.dying;
        sched_lock.unlock();

        if (maybe_next_thread == null and !dying and isEnqueued(current_thread)) {
            apic.eoi();
            apic.timerOneShot(quantum, sched_vector);
            return;
        }

        current_thread.ctx = ctx.*;

        if (arch.arch == .x86_64) {
            current_thread.fs_base = arch.rdmsr(.fs_base);
            current_thread.cr3 = arch.readRegister("cr3");
            arch.cpu.fpuSave(current_thread.fpu_storage);
        }

        // The interrupt already switched to IST1. Nothing below may access the
        // outgoing thread after publishing its saved context to another CPU.
        cpu.current_thread = null;
        cpu.tss.ist2 = cpu.tss.rsp0;
        if (dying) {
            vmm.switchPageTable(vmm.kaddr_space.cr3());
            current_thread.deinit();
        } else {
            current_thread.lock.unlock();
        }
    }

    if (maybe_next_thread) |next_thread| {
        if (arch.arch == .x86_64) {
            arch.wrmsr(.fs_base, next_thread.fs_base);
            cpu.current_thread = next_thread;

            // TODO: SYSENTER: syscall
            // if (sysenter) {
            //     arch.wrmsr(0x175, @intFromPtr(next_thread.kernel_stack));
            // } else {
            //     cpu.tss.ist3 = @intFromPtr(next_thread.kernel_stack);
            // }

            cpu.tss.ist2 = next_thread.pf_stack;

            vmm.switchPageTable(next_thread.cr3);

            arch.cpu.fpuRestore(next_thread.fpu_storage);
        }

        apic.eoi();
        apic.timerOneShot(quantum, sched_vector);
        contextSwitch(&next_thread.ctx);
    } else {
        cpu.current_thread = null;
        vmm.switchPageTable(vmm.kaddr_space.cr3());
        apic.eoi();
        apic.timerOneShot(quantum, sched_vector);
        // STI's interrupt shadow closes the wakeup window before HLT.
        while (true) asm volatile ("sti; hlt" ::: "memory");
    }
    unreachable;
}

pub fn yield() void {
    const interrupt_state = arch.toggleInterrupts(false);
    defer _ = arch.toggleInterrupts(interrupt_state);
    const thread = currentThread();
    sched_lock.lock();
    thread.reschedule_pending = true;
    sched_lock.unlock();

    apic.timerStop();
    apic.sendIPI(undefined, .{ .vector = sched_vector, .destination_shorthand = .self });
    while (true) {
        sched_lock.lock();
        const pending = thread.reschedule_pending;
        sched_lock.unlock();
        if (!pending) break;
        asm volatile ("sti; hlt; cli" ::: "memory");
    }
}

// Lock order is event locks (ascending address), then sched_lock. These
// transitions never acquire an event lock or allocate while holding sched_lock.
pub fn beginEventWait(thread: *Thread) void {
    std.debug.assert(!arch.interruptState());
    sched_lock.lock();
    defer sched_lock.unlock();
    std.debug.assert(!thread.waiting_event and !thread.dying);
    thread.waiting_event = true;
    thread.which_event = std.math.maxInt(usize);
    dequeueLocked(thread);
}

pub fn wakeEventWait(thread: *Thread, which: usize) bool {
    sched_lock.lock();
    if (!thread.waiting_event or thread.dying) {
        sched_lock.unlock();
        return false;
    }
    thread.waiting_event = false;
    thread.which_event = which;
    enqueueLocked(thread) catch unreachable;
    sched_lock.unlock();
    notifyRunnable();
    return true;
}

pub fn eventWaitResult(thread: *Thread) usize {
    sched_lock.lock();
    defer sched_lock.unlock();
    std.debug.assert(!thread.waiting_event);
    return thread.which_event;
}

// The caller has already removed the thread while holding its event locks.
// Never dequeue here: a trigger may have re-enqueued it before this call.
pub fn yieldAwait() void {
    std.debug.assert(!arch.interruptState());
    yield();
}

fn contextSwitch(ctx: *arch.Context) noreturn {
    std.debug.assert(ctx.cs == gdt.kernel_code);
    // TODO: switch page table?
    asm volatile (
        \\mov %[ctx], %rsp
        \\pop %rax
        \\mov %ax, %ds
        \\pop %rax
        \\mov %ax, %es
        \\pop %rax
        \\pop %rbx
        \\pop %rcx
        \\pop %rdx
        \\pop %rsi
        \\pop %rdi
        \\pop %rbp
        \\pop %r8
        \\pop %r9
        \\pop %r10
        \\pop %r11
        \\pop %r12
        \\pop %r13
        \\pop %r14
        \\pop %r15
        \\swapgs
        \\add $16, %rsp
        \\iretq
        :
        : [ctx] "rm" (ctx),
        : "memory"
    );
    unreachable;
}
