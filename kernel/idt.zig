const std = @import("std");
const arch = @import("arch.zig");
const cpu = @import("cpu.zig");
const log = std.log.scoped(.idt);

pub const page_fault_vector = 0x0e;

const interrupt_gate = 0b1000_1110;
const call_gate = 0b1000_1100;
const trap_gate = 0b1000_1111;

const InterruptStub = *const fn () callconv(.Naked) void;
pub const InterruptHandler = *const fn (ctx: *cpu.Context) void;

/// Interrupt Descriptor Table Entry
const IDTEntry = extern struct {
    offset_low: u16 align(1),
    selector: u16 align(1),
    ist: u8 align(1),
    type_attributes: u8 align(1),
    offset_mid: u16 align(1),
    offset_high: u32 align(1),
    reserved: u32 align(1),

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
        // log.info("init idt[{}] with {}", .{ i, handler });
    }

    reload();
    log.info("init: successfully reloaded IDT", .{});
}

pub fn reload() void {
    asm volatile (
        \\lidt (%[idtr])
        :
        : [idtr] "r" (&idtr),
        : "memory"
    );
}

pub fn allocateVector() u8 {
    const vector = @atomicRmw(u8, &next_vector, .Add, 1, .AcqRel);
    if (vector >= 256 - 16) { // TODO - 16 ? also u8 so care about overflows
        @panic("IDT exhausted");
    }
    return vector;
}

pub inline fn setIST(vector: u8, ist: u8) void {
    idt[vector].ist = ist;
}

pub inline fn registerHandler(vector: u8, handler: InterruptHandler) void {
    isr[vector] = handler;
}

fn exceptionHandler(ctx: *cpu.Context) void {
    const vector = ctx.isr_vector;
    const cr2 = arch.readRegister("cr2");
    const cr3 = arch.readRegister("cr3");

    std.debug.panic(
        \\Unhandled exception "{?s}" triggered, dumping context
        \\vector: 0x{x:0>2}               error code: 0x{x}
        \\ds:  0x{x:0>16}    es:     0x{x:0>16}
        \\rax: 0x{x:0>16}    rbx:    0x{x:0>16}
        \\rcx: 0x{x:0>16}    rdx:    0x{x:0>16}
        \\rsi: 0x{x:0>16}    rdi:    0x{x:0>16}
        \\rbp: 0x{x:0>16}    r8:     0x{x:0>16}
        \\r9:  0x{x:0>16}    r10:    0x{x:0>16}
        \\r11: 0x{x:0>16}    r12:    0x{x:0>16}
        \\r13: 0x{x:0>16}    r14:    0x{x:0>16}
        \\r15: 0x{x:0>16}    rip:    0x{x:0>16}
        \\cs:  0x{x:0>16}    rflags: 0x{x:0>16}
        \\rsp: 0x{x:0>16}    ss:     0x{x:0>16}
        \\cr2: 0x{x:0>16}    cr3:    0x{x:0>16}
    , .{
        if (vector < exceptions.len) exceptions[vector] else null,
        vector,
        ctx.error_code,
        ctx.ds,
        ctx.es,
        ctx.rax,
        ctx.rbx,
        ctx.rcx,
        ctx.rdx,
        ctx.rsi,
        ctx.rdi,
        ctx.rbp,
        ctx.r8,
        ctx.r9,
        ctx.r10,
        ctx.r11,
        ctx.r12,
        ctx.r13,
        ctx.r14,
        ctx.r15,
        ctx.rip,
        ctx.cs,
        ctx.rflags,
        ctx.rsp,
        ctx.ss,
        cr2,
        cr3,
    });
}

fn makeStubHandler(vector: u8) InterruptStub {
    return struct {
        fn handler() callconv(.Naked) void {
            const has_error_code = switch (vector) {
                0x8 => true,
                0xa...0xe => true,
                0x11 => true,
                0x15 => true,
                0x1d...0x1e => true,
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

export fn interruptHandler(ctx: *cpu.Context) callconv(.C) void {
    const handler = isr[ctx.isr_vector];
    handler(ctx);
}

export fn commonStub() callconv(.Naked) void {
    asm volatile (
    // if (cs != gdt.kernel_code) -> swapgs
        \\cmpq $0x08, 24(%%rsp)
        \\je 1f
        \\swapgs
        \\1:
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
        // if (cs != gdt.kernel_code) -> swapgs
        \\cmpq $0x08, 24(%%rsp)
        \\je 1f
        \\swapgs
        \\1:
        // restore stack
        \\add $16, %%rsp
        \\iretq
    );
}
