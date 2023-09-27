const std = @import("std");
const SpinLock = @import("lock.zig").SpinLock;

// TODO: defined elsewhere
pub const Thread = struct {};

pub const Context = struct {
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
    //vector: u64,
    err: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

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
    cpu_number: u32,
    bsp: bool,
    active: bool,
    last_run_queue_index: u32,
    lapic_id: u32,
    lapic_freq: u64,
    tss: TSS,
    idle_thread: *Thread,
    tlb_shootdown_lock: SpinLock,
    tlb_shootdown_done: SpinLock,
    tlb_shootdown_cr3: usize, // TODO: uintptr_t

};

pub var sysenter: bool = false;
pub var bsp_lapic_id: u32 = undefined;
pub var smp_started: bool = undefined;

pub var cpus: []CpuLocal = undefined;

pub var fpu_storage_size: usize = 0;
// extern void (*fpu_save)(void *ctx);
// extern void (*fpu_restore)(void *ctx);

pub var cpu_count: usize = undefined;

pub fn init() void {}

// TODO: a lot of functions with inline assembly
