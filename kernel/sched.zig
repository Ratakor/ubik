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

// This is a draft for the Full Random Scheduler

// TODO: if a process create a lot of thread it can suck all the cpu
//       -> check the process of the chosen thread smh to fix that
// TODO: use a red-black tree instead of a skiplist ?

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

    pub fn init(old_process: ?*Process, addr_space: ?*vmm.AddressSpace) !*Process {
        const proc = try root.allocator.create(Process);
        errdefer root.allocator.destroy(proc);

        try processes.append(root.allocator, proc);
        errdefer _ = processes.popOrNull(); // TODO: or just assume push to old_proc won't fail :D
        proc.pid = processes.items.len - 1;
        proc.parent = old_process;
        proc.threads = .{};
        proc.children = .{};

        if (old_process) |old_proc| {
            @memcpy(&proc.name, &old_proc.name);
            // proc.addr_space = try old_proc.addr_space.fork();
            // proc.thread_stack_top = old_proc.thread_stack_top;
            // proc.mmap_anon_base = old_proc.mmap_anon_base;
            // proc.cwd = old_proc.cwd;
            // proc.umask = old_proc.umask;

            try old_proc.children.append(root.allocator, proc);
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

// TODO: extern ?
pub const Thread = struct {
    self: *Thread, // TODO
    errno: usize, // TODO

    tid: u32,
    lock: SpinLock = .{},
    cpu: *smp.CpuLocal,
    process: *Process,
    ctx: arch.Context,

    ticket: usize,
    ntickets: usize,

    scheduling_off: bool,
    enqueued: bool, // TODO: useless?
    enqueued_by_signal: bool,
    timeslice: u32,
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

    pub const stack_size = 0x40000; // TODO
    pub const stack_pages = stack_size / page_size;

    // TODO: improve
    //       use root.allocator instead of pmm.alloc?
    pub fn initKernel(func: *const anyopaque, arg: ?*anyopaque) !*Thread {
        const thread = try root.allocator.create(Thread);
        errdefer root.allocator.destroy(thread);
        @memset(std.mem.asBytes(thread), 0);

        thread.self = thread;
        thread.errno = 0;

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
        // thread.ctx.rflags = 0x202; // TODO: check osdev, this is better in 0b
        thread.ctx.rip = @intFromPtr(func);
        thread.ctx.rdi = @intFromPtr(arg);
        thread.ctx.rsp = stack;

        thread.cr3 = kernel_process.addr_space.page_table.cr3();
        thread.gs_base = @intFromPtr(thread);

        thread.process = kernel_process;
        thread.timeslice = 5000; // TODO
        // TODO: calculate this once and store it in arch.cpu.fpu_storage_pages
        const pages = std.math.divCeil(u64, arch.cpu.fpu_storage_size, page_size) catch unreachable;
        const fpu_storage_phys = pmm.alloc(pages, true) orelse {
            pmm.free(stack_phys, stack_pages);
            root.allocator.destroy(thread);
            return error.OutOfMemory;
        };
        thread.fpu_storage = fpu_storage_phys + vmm.hhdm_offset;

        return thread;
    }

    // TODO: idk if this should be in kernel, it is pthread
    pub fn initUser() !*Thread {
        @compileError("TODO");
    }

    // TODO
    pub fn deinit(self: *Thread) void {
        // for (self.stacks.items) |stack| {
        //     pmm.free(stack - vmm.hhdm_offset - stack_size, stack_pages);
        // }
        // TODO: calculate this once and store it in arch.cpu.fpu_storage_pages
        const pages = std.math.divCeil(u64, arch.cpu.fpu_storage_size, page_size) catch unreachable;
        pmm.free(self.fpu_storage - vmm.hhdm_offset, pages);
        root.allocator.destroy(self);
    }

    pub fn enqueue(self: *Thread, ntickets: usize) !void {
        if (self.enqueued) return;

        self.ticket = tickets_count.fetchAdd(ntickets, .AcqRel) + ntickets; // TODO: ordering
        self.ntickets = ntickets;
        _ = try running_threads.insert(self);
        self.enqueued = true;

        for (smp.cpus) |cpu| {
            if (!cpu.active) {
                apic.sendIPI(cpu.lapic_id, sched_vector);
                break;
            }
        }

        log.info("enqueued thread: {*} with ticket: {}", .{ self, self.ticket });
    }

    pub fn dequeue(self: *Thread) void {
        if (!self.enqueued) return;

        std.debug.assert(running_threads.remove(self.ticket));
        _ = tickets_count.fetchSub(self.ntickets, .AcqRel); // TODO: ordering
        self.enqueued = false;

        log.info("dequeued thread: {*} with ticket: {}", .{ self, self.ticket });
    }
};

const ThreadSkipList = struct {
    const Self = @This();
    const Error = std.mem.Allocator.Error;

    header: *Node,
    count: usize = 0,
    level: usize = 1,
    lock: SpinLock = .{}, // TODO: fine grained lock instead of global

    pub const max_level = 32;

    pub const Node = struct {
        thread: *Thread,
        forward: []?*Node,

        pub inline fn next(self: Node) ?*Node {
            return self.forward[0];
        }
    };

    pub fn init() Error!Self {
        const node = try root.allocator.create(Node);
        node.forward = try root.allocator.alloc(?*Node, max_level);
        @memset(node.forward, null);
        return .{ .header = node };
    }

    pub fn deinit(self: Self) void {
        var node: ?*Node = self.header;
        while (node) |n| {
            node = n.next();
            root.allocator.free(n.forward);
            root.allocator.destroy(n);
        }
    }

    fn find(self: *Self, ticket: usize, update: []*Node) ?*Node {
        var node: *Node = self.header;
        var lvl = self.level - 1;

        while (true) : (lvl -= 1) {
            while (node.forward[lvl]) |next| {
                if (next.thread.ticket >= ticket) break;
                node = next;
            }
            update[lvl] = node;

            if (lvl == 0) break;
        }

        return node.next();
    }

    pub fn insert(self: *Self, thread: *Thread) Error!*Node {
        self.lock.lock();
        defer self.lock.unlock();

        var update: [max_level]*Node = undefined;
        const maybe_node = self.find(thread.ticket, &update);

        if (maybe_node) |node| {
            std.debug.panic(
                \\trying to insert an already inserted thread
                \\node.thread.ticket = {}
                \\thread.ticket = {}
            , .{ node.thread.ticket, thread.ticket });
        }

        var lvl: usize = 1;
        while (random.int(u2) == 0) lvl += 1;
        if (lvl > self.level) {
            if (lvl > max_level) lvl = max_level;
            for (self.level..lvl) |i| {
                update[i] = self.header;
            }
            self.level = lvl;
        }

        var node = try root.allocator.create(Node);
        node.thread = thread;
        node.forward = try root.allocator.alloc(?*Node, lvl);

        for (0..lvl) |i| {
            node.forward[i] = update[i].forward[i];
            update[i].forward[i] = node;
        }

        self.count += 1;

        return node;
    }

    pub fn remove(self: *Self, ticket: usize) bool {
        self.lock.lock();
        defer self.lock.unlock();

        var update: [max_level]*Node = undefined;
        if (self.find(ticket, &update)) |node| {
            if (node.thread.ticket == ticket) {
                for (0..self.level) |lvl| {
                    if (update[lvl].forward[lvl] != node) break;
                    update[lvl].forward[lvl] = node.forward[lvl];
                }

                while (self.level > 1) : (self.level -= 1) {
                    if (self.header.forward[self.level - 1] != null) break;
                }

                self.count -= 1;
                root.allocator.free(node.forward);
                root.allocator.destroy(node);
                return true;
            }
        }
        return false;
    }

    pub inline fn getThread(self: *Self, ticket: usize) ?*Thread {
        self.lock.lock();
        defer self.lock.unlock();

        var node: *Node = self.header;
        var lvl = self.level - 1;

        while (true) : (lvl -= 1) {
            while (node.forward[lvl]) |next| {
                if (next.thread.ticket >= ticket) break;
                node = next;
            }
            if (lvl == 0) break;
        }

        return if (node.next()) |n| n.thread else null;
    }

    pub inline fn first(self: Self) ?*Node {
        return self.header.forward[0];
    }
};

pub var kernel_process: *Process = undefined;
pub var processes: std.ArrayListUnmanaged(*Process) = .{};
var sched_vector: u8 = undefined;
var running_threads: ThreadSkipList = undefined;
var tickets_count = std.atomic.Atomic(usize).init(0);
var pcg: rand.Pcg = undefined;
const random: rand.Random = pcg.random(); // TODO: useless use pcg.random()?

pub fn init() void {
    pcg = rand.Pcg.init(rand.getSeedSlow());
    running_threads = ThreadSkipList.init() catch unreachable;
    kernel_process = Process.init(null, &vmm.kernel_addr_space) catch unreachable;

    sched_vector = idt.allocVector();
    log.info("scheduler interrupt vector: 0x{x}", .{sched_vector});
    idt.registerHandler(sched_vector, schedHandler);
    // idt.setIST(sched_vector, 1);
}

pub inline fn currentThread() *Thread {
    return asm volatile (
        \\mov %%gs:0x0, %[thr]
        : [thr] "=r" (-> *Thread),
    );
}

fn nextThread() ?*Thread {
    // TODO: use uintLessThanBiased? <- cmp if speed diff is really important
    const ticket = random.uintLessThan(usize, tickets_count.load(.Acquire) + 1); // TODO: ordering
    return running_threads.getThread(ticket);
}

/// dequeue current thread and yield
pub fn dequeueAndDie() noreturn {
    arch.disableInterrupts();
    currentThread().dequeue();
    yield(false);
    unreachable;
}

fn schedHandler(ctx: *arch.Context) void {
    apic.timerStop();

    var current_thread = currentThread();
    std.debug.assert(@intFromPtr(current_thread) != 0);
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

        current_thread.lock.unlock();
    }

    if (next_thread == null) {
        apic.eoi();
        if (arch.arch == .x86_64) {
            arch.setGsBase(@intFromPtr(cpu.idle));
            arch.setKernelGsBase(@intFromPtr(cpu.idle));
        }
        cpu.active = false;
        vmm.switchPageTable(vmm.kernel_addr_space.page_table.cr3());
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
        //     cpu.tss.ist3 = @intFromPtr(current_thread.kernel_stack);
        // }

        // TODO: set page fault stack
        // cpu.tss.ist2 = @intFromPtr(current_thread.pf_stack);

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
    apic.timerOneShot(1_000, sched_vector);
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
        \\swapgs
        \\add $16, %%rsp
        \\iretq
        :
        : [ctx] "rm" (ctx),
        : "memory"
    );
    unreachable;
}
