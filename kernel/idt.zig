const std = @import("std");
const cpu = @import("cpu.zig");

// TODO
// const syscall_vector = 0xFD;
// const sched_call_vector = 0xFE;
// const spurious_vector = 0xFF;

const page_fault = 0xE;

const interrupt_gate = 0b1000_1110;
const call_gate = 0b1000_1100;
const trap_gate = 0b1000_1111;

const InterruptStub = *const fn () callconv(.Naked) void;
pub const InterruptHandler = *const fn (ctx: *cpu.Context) void;

const IDTEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attributes: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32,

    fn init(handler: u64, ist: u8, attributes: u8) IDTEntry {
        return .{
            .offset_low = @truncate(handler),
            .selector = 0x08, // gdt.kernel_code
            .ist = ist,
            .type_attributes = attributes,
            .offset_mid = @truncate(handler >> 16),
            .offset_high = @truncate(handler >> 32),
            .reserved = 0,
        };
    }
};

const IDTRegister = extern struct {
    limit: u16 align(1) = @sizeOf(@TypeOf(idt)) - 1,
    base: u64 align(1) = undefined,
};

const exceptions = [_][]const u8{
    "Division by zero",
    "Debug",
    "Non-maskable Interrupt",
    "Breakpoint",
    "Overflow",
    "Bound Range Exceeded",
    "Invalid Opcode",
    "Device Not Available",
    "Double Fault",
    "Coprocessor Segment Overrun",
    "Invalid TSS",
    "Segment Not Present",
    "Stack-Segment Fault",
    "General Protection Fault",
    "Page Fault",
    "",
    "x87 Floating-Point Exception",
    "Alignment Check",
    "Machine Check",
    "SIMD Floating-Point Exception",
    "Virtualization Exception",
    "Control Protection Exception",
    "",
    "",
    "",
    "",
    "",
    "",
    "Hypervisor Injection Exception",
    "VMM Communication Exception",
    "Security Exception",
    "",
};

var isr = [_]InterruptHandler{exceptionHandler} ** 256;
var next_vector: u8 = exceptions.len;

var idtr: IDTRegister = .{};
var idt: [256]IDTEntry = undefined;

pub fn init() void {
    idtr.base = @intFromPtr(&idt);

    inline for (0..256) |i| {
        const handler = comptime makeStubHandler(i);
        idt[i] = IDTEntry.init(@intFromPtr(handler), 0, interrupt_gate);
    }

    // idt[sched_call_vector].ist = 1;
    // idt[syscall_vector].type_attributes = 0xEE;

    reloadIDT();
}

pub fn reloadIDT() void {
    asm volatile ("lidt (%[idtr])"
        :
        : [idtr] "r" (&idtr),
        : "memory"
    );
}

pub fn allocateVector() u8 {
    const vector = @atomicRmw(u8, &next_vector, .Add, 1, .AcqRel);
    if (vector >= 256 - 16) {
        @panic("IDT exhausted");
    }
    return vector;
}

pub fn registerHandler(vector: u8, handler: InterruptHandler) void {
    isr[vector] = handler;
}

fn exceptionHandler(ctx: *cpu.Context) void {
    const vector = ctx.isr_vector;

    // TODO handle stuff
    // if (vector == page_fault and mmap.handlePageFault(ctx)) {
    //     return;
    // }

    if (vector < exceptions.len) {
        std.debug.panic("Exception \"{s}\" triggered with vector: {} and error code: {}", .{
            exceptions[vector],
            vector,
            ctx.error_code,
        });
    } else {
        std.debug.panic("Unhandled exception triggered, dumping context\n{}", .{ctx});
    }
}

fn makeStubHandler(vector: u8) InterruptStub {
    return struct {
        fn handler() callconv(.Naked) void {
            const has_error_code = switch (vector) {
                0x8 => true,
                0xA...0xE => true,
                0x11 => true,
                0x15 => true,
                0x1D...0x1E => true,
                else => false,
            };
            if (!has_error_code) asm volatile ("pushq $0");

            asm volatile (
                \\pushq %[vector]
                \\jmp commonStub
                :
                : [vector] "i" (vector),
            );
        }
    }.handler;
}

// TODO swapgs

export fn interruptHandler(ctx: *cpu.Context) callconv(.C) void {
    // if (ctx.cs != 0x08) {
    //     asm volatile ("swapgs");
    // }
    const handler = isr[ctx.isr_vector];
    handler(ctx);
    // if (ctx.cs != 0x08) {
    //     asm volatile ("swapgs");
    // }
}

export fn commonStub() callconv(.Naked) void {
    asm volatile (
    // \\cmpq $0x08, 0x8(%%rsp)
    // \\je 1f
    // \\swapgs
    // \\1:
        \\push %%r15
        \\push %%r14
        \\push %%r13
        \\push %%r12
        \\push %%r11
        \\push %%r10
        \\push %%r9
        \\push %%r8
        \\push %%rbp
        \\push %%rdi
        \\push %%rsi
        \\push %%rdx
        \\push %%rcx
        \\push %%rbx
        \\push %%rax
        \\mov %%es, %%ax
        \\push %%rax
        \\mov %%ds, %%ax
        \\push %%rax
        \\
        \\mov %%rsp, %%rdi
        \\call interruptHandler
        \\
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
        \\add $16, %%rsp
        \\
        // \\cmpq $0x08, 0x8(%%rsp)
        // \\je 1f
        // \\swapgs
        // \\1:
        \\iretq
    );
}
