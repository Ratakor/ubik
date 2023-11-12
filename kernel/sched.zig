const std = @import("std");
const root = @import("root");
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
    child_events: std.ArrayListUnmanaged(*Event),
    event: Event,
    // running_time: usize, // TODO
    user: std.os.uid_t,
    group: std.os.gid_t,

    // I/O context
    cwd: *vfs.Node,
    umask: std.os.mode_t,
    fds_lock: SpinLock,
    fds: std.ArrayListUnmanaged(*vfs.FileDescriptor),

    var next_pid = std.atomic.Atomic(std.os.pid_t).init(0);

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
            process.umask = std.os.S.IWGRP | std.os.S.IWOTH;
        }

        try processes.append(root.allocator, process);
        process.id = next_pid.fetchAdd(1, .Release);

        return process;
    }

    pub fn deinit(self: *Process) void {
        // TODO: items of each arraylist + addr_space + parent + processes

        self.threads.deinit();
        self.children.deinit();
        self.child_events.deinit();
        self.fds.deinit();
        root.allocator.destroy(self);
    }
};

pub const Thread = struct {
    errno: usize,
    tid: usize,
    lock: SpinLock = .{},
    process: *Process,
    ctx: arch.Context,

    tickets: usize,

    enqueued: bool,
    // enqueued_by_signal: bool, // TODO: for events
    yield_await: SpinLock = .{},
    // gs_base
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
            .errno = 0,
            .tid = undefined,
            .process = kernel_process,
            .ctx = undefined, // defined after
            .tickets = tickets,
            .enqueued = false,
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
};

/// reschedule every 5ms
pub const timeslice = 5_000;
/// wait for 10ms if there is no thread
pub const wait_timeslice = 10_000;

pub var kernel_process: *Process = undefined;
pub var processes: std.ArrayListUnmanaged(*Process) = .{}; // TODO: hashmap with pid?
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

pub inline fn currentThread() *Thread {
    return smp.thisCpu().current_thread.?;
}

pub inline fn currentProcess() *Process {
    return currentThread().process;
}

pub inline fn setErrno(errno: std.os.E) void {
    currentThread().errno = @intFromEnum(errno);
}

fn nextThread() ?*Thread {
    const ticket = pcg.random().uintLessThan(usize, total_tickets + 1);
    var sum: usize = 0;

    sched_lock.lock();
    defer sched_lock.unlock();

    var iter = running_threads.iterator();
    while (iter.next()) |entry| {
        const thread = entry.key_ptr.*;
        sum += thread.tickets;
        if (sum >= ticket and thread.lock.tryLock()) {
            return thread;
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
        if (cpu.current_thread == null) {
            apic.sendIPI(cpu.lapic_id, .{ .vector = sched_vector });
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
    current_thread.deinit(); // TODO: ?
    yield();
}

fn schedHandler(ctx: *arch.Context) callconv(.SysV) void {
    apic.timerStop();

    const cpu = smp.thisCpu();

    // if (cpu.scheduling_disabled) {
    //     apic.eoi();
    //     apic.timerOneShot(timeslice, sched_vector);
    //     return;
    // }

    const maybe_next_thread = nextThread();

    if (cpu.current_thread) |current_thread| {
        // current_thread.yield_await.unlock(); // TODO

        if (maybe_next_thread == null and current_thread.enqueued) {
            apic.eoi();
            apic.timerOneShot(timeslice, sched_vector);
            return;
        }

        current_thread.ctx = ctx.*;

        if (comptime arch.arch == .x86_64) {
            current_thread.fs_base = arch.rdmsr(.fs_base);
            current_thread.cr3 = arch.readRegister("cr3");
            arch.cpu.fpuSave(current_thread.fpu_storage);
        }

        current_thread.lock.unlock();
    }

    if (maybe_next_thread) |next_thread| {
        if (comptime arch.arch == .x86_64) {
            arch.wrmsr(.fs_base, next_thread.fs_base);
            cpu.current_thread = next_thread;

            // TODO: SYSENTER: syscall
            // if (sysenter) {
            //     arch.wrmsr(0x175, @intFromPtr(next_thread.kernel_stack));
            // } else {
            //     cpu.tss.ist3 = @intFromPtr(next_thread.kernel_stack);
            // }

            cpu.tss.ist2 = next_thread.pf_stack;

            if (arch.readRegister("cr3") != next_thread.cr3) {
                arch.writeRegister("cr3", next_thread.cr3);
            }

            arch.cpu.fpuRestore(next_thread.fpu_storage);
        }

        apic.eoi();
        apic.timerOneShot(timeslice, sched_vector);
        contextSwitch(&next_thread.ctx);
    } else {
        cpu.current_thread = null;
        vmm.switchPageTable(vmm.kaddr_space.cr3());
        apic.eoi();
        wait();
    }
    unreachable;
}

pub fn wait() noreturn {
    arch.disableInterrupts();
    apic.timerOneShot(wait_timeslice, sched_vector);
    arch.enableInterrupts();
    arch.halt();
}

pub fn yield() noreturn {
    arch.disableInterrupts();
    apic.timerStop();

    const cpu = smp.thisCpu();
    cpu.current_thread = null;
    apic.sendIPI(cpu.lapic_id, .{ .vector = sched_vector });

    arch.enableInterrupts();
    arch.halt();
}

// TODO
pub fn yieldAwait() void {
    std.debug.assert(arch.interruptState() == false);

    apic.timerStop();

    const thread = currentThread();
    thread.yield_await.lock();

    apic.sendIPI(undefined, .{ .vector = sched_vector, .destination_shorthand = .self });
    arch.enableInterrupts();

    // TODO: useless since yield_await should already be unlocked
    thread.yield_await.lock();
    thread.yield_await.unlock();
}

fn contextSwitch(ctx: *arch.Context) noreturn {
    std.debug.assert(ctx.cs == gdt.kernel_code);
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
