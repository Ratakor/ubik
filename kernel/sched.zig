const std = @import("std");
const root = @import("root");
const arch = @import("arch.zig");
const gdt = arch.gdt;
const idt = arch.idt;
const apic = arch.apic;
const rand = @import("rand.zig");
const smp = @import("smp.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const vfs = @import("vfs.zig");
const Event = @import("event.zig").Event;
const SpinLock = root.SpinLock;
const log = std.log.scoped(.sched);

// TODO: if a process create a lot of thread it can suck all the cpu
//       -> check the process of the chosen thread smh to fix that

pub const Process = struct {
    id: std.os.pid_t,
    name: [127:0]u8,
    parent: ?*Process,
    addr_space: *vmm.AddressSpace,
    mmap_anon_base: usize, // TODO
    thread_stack_top: usize, // TODO
    threads: std.ArrayListUnmanaged(*Thread),
    children: std.ArrayListUnmanaged(*Process),
    // child_events
    // event: Event
    // cwd: *vfs.Node,
    umask: u32,
    fds_lock: SpinLock,
    fds: std.ArrayListUnmanaged(*vfs.FileDescriptor), // TODO: hashmap?
    // running_time: usize, // TODO

    var next_pid = std.atomic.Atomic(std.os.pid_t).init(0);

    pub fn init(parent: ?*Process, addr_space: ?*vmm.AddressSpace) !*Process {
        const proc = try root.allocator.create(Process);
        errdefer root.allocator.destroy(proc);

        proc.parent = parent;
        proc.threads = .{};
        proc.children = .{};

        if (parent) |p| {
            @memcpy(&proc.name, &p.name);
            proc.addr_space = try p.addr_space.fork();
            // proc.thread_stack_top = p.thread_stack_top;
            // proc.mmap_anon_base = p.mmap_anon_base;
            // proc.cwd = p.cwd;
            proc.umask = p.umask;

            try p.children.append(root.allocator, proc);
            // try old_proc.child_events.append(root.allocator, &proc.event);
        } else {
            @memset(&proc.name, 0);
            proc.addr_space = addr_space.?;
            // proc.thread_stack_top = 0x70000000000;
            // proc.mmap_anon_base = 0x80000000000;
            // proc.cwd = vfs.root_node;
            proc.umask = std.os.S.IWGRP | std.os.S.IWOTH;
        }

        try processes.append(root.allocator, proc);
        proc.id = next_pid.fetchAdd(1, .Release);

        return proc;
    }

    pub fn deinit(self: *Process) void {
        _ = self;
        // TODO
    }
};

pub const Thread = struct {
    self: *Thread,
    errno: u64,

    tid: usize,
    lock: SpinLock = .{},
    cpu: ?*arch.cpu.CpuLocal,
    process: *Process,
    ctx: arch.Context,

    tickets: usize,

    scheduling_off: bool, // TODO: for TLB
    enqueued: bool,
    // enqueued_by_signal: bool, // TODO: for events
    yield_await: SpinLock = .{},
    gs_base: u64,
    fs_base: u64,
    cr3: u64,
    fpu_storage: u64,
    stacks: std.ArrayListUnmanaged(u64) = .{},
    pf_stack: u64,
    kernel_stack: u64,

    which_event: usize,
    attached_events: std.ArrayListUnmanaged(*Event),

    // running_time: usize, // TODO

    const Set = std.AutoArrayHashMapUnmanaged(*Thread, void);
    pub const max_events = 32;
    pub const stack_size = 8 * 1024 * 1024; // 8MiB
    pub const stack_pages = stack_size / std.mem.page_size;

    // TODO: merge initUser and initKernel?
    pub fn initKernel(func: *const anyopaque, arg: ?*anyopaque, tickets: usize) !*Thread {
        const thread = try root.allocator.create(Thread);
        errdefer root.allocator.destroy(thread);

        thread.* = .{
            .self = thread,
            .errno = 0,
            .tid = undefined,
            .cpu = null,
            .process = kernel_process,
            .ctx = undefined, // defined after
            .tickets = tickets,
            .scheduling_off = false,
            .enqueued = false,
            .gs_base = @intFromPtr(thread),
            .fs_base = undefined,
            .cr3 = kernel_process.addr_space.cr3(),
            .fpu_storage = undefined, // defined after
            .pf_stack = undefined,
            .kernel_stack = undefined,
            .which_event = undefined,
            .attached_events = try std.ArrayListUnmanaged(*Event).initCapacity(root.allocator, max_events),
        };
        errdefer thread.attached_events.deinit(root.allocator);

        const fpu_storage = try root.allocator.alloc(u8, arch.cpu.fpu_storage_size);
        errdefer root.allocator.free(fpu_storage);
        @memset(fpu_storage, 0);
        thread.fpu_storage = @intFromPtr(fpu_storage.ptr);

        thread.ctx.cs = gdt.kernel_code;
        thread.ctx.ds = gdt.kernel_data;
        thread.ctx.es = gdt.kernel_data;
        thread.ctx.ss = gdt.kernel_data;
        thread.ctx.rflags = @bitCast(arch.RFlags{ .IF = 1 });
        thread.ctx.rip = @intFromPtr(func);
        thread.ctx.rdi = @intFromPtr(arg);
        thread.ctx.rsp = blk: {
            // TODO: use root.allocator
            const stack_phys = pmm.alloc(stack_pages, true) orelse return error.OutOfMemory;
            errdefer pmm.free(stack_phys, stack_pages);
            try thread.stacks.append(root.allocator, stack_phys);
            break :blk stack_phys + stack_size + vmm.hhdm_offset;
        };

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

        thread.self = thread;
        thread.process = process;
        thread.tickets = tickets;
        thread.lock = .{};
        thread.enqueued = false;
        thread.yield_await = .{};
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
                vmm.PROT.READ | vmm.PROT.WRITE,
                vmm.MAP.ANONYMOUS,
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

    pub fn deinit(self: *Thread) void {
        for (self.stacks.items) |stack| {
            pmm.free(stack, stack_pages);
        }
        self.stacks.deinit(root.allocator);
        self.attached_events.deinit(root.allocator);
        const fpu_storage: [*]u8 = @ptrFromInt(self.fpu_storage);
        root.allocator.free(fpu_storage[0..arch.cpu.fpu_storage_size]);
        root.allocator.destroy(self);
    }

    comptime {
        const thread: *Thread = @ptrFromInt(0xdead69420);
        std.debug.assert(@intFromPtr(thread) == @intFromPtr(&thread.self));
        std.debug.assert(@intFromPtr(thread) + 8 == @intFromPtr(&thread.errno)); // TODO: needed?
    }
};

/// reschedule every 1ms
pub const timeslice = 1000;

pub var kernel_process: *Process = undefined;
pub var processes: std.ArrayListUnmanaged(*Process) = .{};
var running_threads: Thread.Set = .{};
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

// TODO: save cpu in gs not thread -> remove .cpu from Thread
pub inline fn currentThread() *Thread {
    return asm volatile (
        \\mov %gs:0x0, %[thr]
        : [thr] "=r" (-> *Thread),
    );
}

pub inline fn setErrno(errno: std.os.E) void {
    currentThread().errno = @intFromEnum(errno);
}

// TODO: improve speed
fn nextThread() ?*Thread {
    const ticket = pcg.random().uintLessThan(usize, total_tickets + 1);
    var sum: usize = 0;

    sched_lock.lock();
    defer sched_lock.unlock();

    var iter = running_threads.iterator();
    while (iter.next()) |entry| {
        const thread = entry.key_ptr.*;
        sum += thread.tickets;
        if (sum >= ticket) {
            return if (thread.lock.tryLock()) thread else null;
        }
    }
    return null;
}

pub fn enqueue(thread: *Thread) !void {
    if (thread.enqueued) return;

    sched_lock.lock();
    errdefer sched_lock.unlock();

    try running_threads.putNoClobber(root.allocator, thread, {});
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

pub fn dequeue(thread: *Thread) void {
    if (!thread.enqueued) return;

    sched_lock.lock();
    defer sched_lock.unlock();

    if (running_threads.swapRemove(thread)) {
        total_tickets -= thread.tickets;
        thread.enqueued = false;
        log.info("dequeued thread: {*}", .{thread});
    } else {
        log.warn("trying to dequeue unknown thread: {*}", .{thread});
    }
}

pub fn die() noreturn {
    arch.disableInterrupts();
    const current_thread = currentThread();
    dequeue(current_thread);
    current_thread.deinit();
    yield(false);
    unreachable;
}

// TODO: improve
fn schedHandler(ctx: *arch.Context) callconv(.SysV) void {
    apic.timerStop();

    var current_thread = currentThread();
    std.debug.assert(@intFromPtr(current_thread) != 0); // TODO

    // TODO
    if (current_thread.scheduling_off) {
        apic.eoi();
        apic.timerOneShot(timeslice, sched_vector);
        return;
    }

    const cpu = smp.thisCpu();
    cpu.active = true;
    const next_thread = nextThread();

    if (current_thread != cpu.idle_thread) {
        current_thread.yield_await.unlock();

        if (next_thread == null and current_thread.enqueued) {
            apic.eoi();
            apic.timerOneShot(timeslice, sched_vector);
            return;
        }

        current_thread.ctx = ctx.*;

        if (arch.arch == .x86_64) {
            current_thread.gs_base = arch.getKernelGsBase();
            current_thread.fs_base = arch.getFsBase();
            current_thread.cr3 = arch.readRegister("cr3");
            arch.cpu.fpuSave(current_thread.fpu_storage);
        }

        current_thread.cpu = null;
        current_thread.lock.unlock();
    }

    if (next_thread == null) {
        apic.eoi();
        if (arch.arch == .x86_64) {
            arch.setGsBase(@intFromPtr(cpu.idle_thread));
            arch.setKernelGsBase(@intFromPtr(cpu.idle_thread));
        }
        cpu.active = false;
        vmm.switchPageTable(vmm.kaddr_space.cr3());
        wait();
    }

    current_thread = next_thread.?;

    if (arch.arch == .x86_64) {
        arch.setGsBase(@intFromPtr(current_thread));
        if (current_thread.ctx.cs == gdt.kernel_code) {
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
    apic.timerOneShot(timeslice, sched_vector);
    contextSwitch(&current_thread.ctx);
}

pub fn wait() noreturn {
    arch.disableInterrupts();
    apic.timerOneShot(timeslice * 5, sched_vector);
    arch.enableInterrupts();
    arch.halt();
}

// TODO: is save_ctx useful?
pub fn yield(save_ctx: bool) void {
    arch.disableInterrupts();
    apic.timerStop();

    const thread = currentThread();
    const cpu = smp.thisCpu();

    if (save_ctx) {
        thread.yield_await.lock();
    } else {
        arch.setGsBase(@intFromPtr(cpu.idle_thread));
        arch.setKernelGsBase(@intFromPtr(cpu.idle_thread));
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
        // TODO: check if user?
        \\swapgs
        \\add $16, %rsp
        \\iretq
        :
        : [ctx] "rm" (ctx),
        : "memory"
    );
    unreachable;
}
