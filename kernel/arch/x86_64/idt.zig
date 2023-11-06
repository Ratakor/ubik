const std = @import("std");
const x86 = @import("x86_64.zig");
const gdt = @import("gdt.zig");
const vmm = @import("root").vmm;
const log = std.log.scoped(.idt);

const interrupt_gate = 0b1000_1110;
const trap_gate = 0b1000_1111;

pub const InterruptHandler = *const fn (ctx: *Context) callconv(.SysV) void;

pub const Context = extern struct {
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
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

/// Interrupt Descriptor Table Entry
const IDTEntry = extern struct {
    offset_low: u16 align(1),
    selector: u16 align(1),
    ist: u8 align(1),
    type_attributes: u8 align(1),
    offset_mid: u16 align(1),
    offset_high: u32 align(1),
    reserved: u32 align(1),

    fn init(handler: u64, ist: u8, gate: u8) IDTEntry {
        return .{
            .offset_low = @truncate(handler),
            .selector = gdt.kernel_code,
            .ist = ist,
            .type_attributes = gate,
            .offset_mid = @truncate(handler >> 16),
            .offset_high = @truncate(handler >> 32),
            .reserved = 0,
        };
    }
};

const IDTDescriptor = extern struct {
    limit: u16 align(1) = @sizeOf(@TypeOf(idt)) - 1,
    base: u64 align(1) = undefined,
};

const exceptions = [_]?[]const u8{
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
    null,
    "x87 Floating-Point Exception",
    "Alignment Check",
    "Machine Check",
    "SIMD Floating-Point Exception",
    "Virtualization Exception",
    "Control Protection Exception",
    null,
    null,
    null,
    null,
    null,
    null,
    "Hypervisor Injection Exception",
    "VMM Communication Exception",
    "Security Exception",
    null,
};

var isr = [_]InterruptHandler{defaultHandler} ** 256;
var next_vector: u8 = exceptions.len;
pub var panic_ipi_vector: u8 = undefined;

var idtr: IDTDescriptor = .{};
var idt: [256]IDTEntry = undefined;

pub fn init() void {
    idtr.base = @intFromPtr(&idt);

    inline for (0..256) |i| {
        const handler = comptime makeStubHandler(i);
        idt[i] = IDTEntry.init(@intFromPtr(handler), 0, interrupt_gate);
        // log.info("init idt[{}] with {}", .{ i, handler });
    }

    setIST(0x0e, 2); // page fault uses IST 2
    panic_ipi_vector = allocVector();
    idt[panic_ipi_vector] = IDTEntry.init(@intFromPtr(&panicHandler), 0, interrupt_gate);

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

pub fn allocVector() u8 {
    const vector = @atomicRmw(u8, &next_vector, .Add, 1, .AcqRel);
    // 0xf0 in a non maskable interrupt from APIC
    if (vector == 0xf0) {
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

fn panicHandler() callconv(.Naked) noreturn {
    x86.disableInterrupts();
    x86.halt();
}

fn defaultHandler(ctx: *Context) callconv(.SysV) void {
    const cr2 = x86.readRegister("cr2");

    if (ctx.cs == gdt.user_code) {
        switch (ctx.vector) {
            0x0e => {
                if (vmm.handlePageFault(cr2, ctx.error_code)) {
                    return;
                } else |err| {
                    log.err("failed to handle page fault: {}", .{err});
                }
            },
            // TODO
            else => {},
        }
    }

    const cr3 = x86.readRegister("cr3");
    std.debug.panic(
        \\Unhandled interruption "{?s}" triggered, dumping context
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
        if (ctx.vector < exceptions.len) exceptions[ctx.vector] else null,
        ctx.vector,
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

fn makeStubHandler(vector: u8) *const fn () callconv(.Naked) void {
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

export fn commonStub() callconv(.Naked) void {
    asm volatile (
    // if (cs != gdt.kernel_code) -> swapgs
        \\cmpq %[kcode], 0x18(%rsp)
        \\je 1f
        \\swapgs
        \\1:
        \\push %r15
        \\push %r14
        \\push %r13
        \\push %r12
        \\push %r11
        \\push %r10
        \\push %r9
        \\push %r8
        \\push %rbp
        \\push %rdi
        \\push %rsi
        \\push %rdx
        \\push %rcx
        \\push %rbx
        \\push %rax
        \\mov %es, %ax
        \\push %rax
        \\mov %ds, %ax
        \\push %rax
        :
        : [kcode] "i" (gdt.kernel_code),
    );

    asm volatile (
        \\mov 0x88(%rsp), %rdi
        \\imul $8, %rdi
        \\add %rdi, %rax
        \\mov %rsp, %rdi
        \\call *(%rax)
        :
        : [_] "{rax}" (&isr),
    );

    asm volatile (
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
        // if (cs != gdt.kernel_code) -> swapgs
        \\cmpq %[kcode], 0x18(%rsp)
        \\je 1f
        \\swapgs
        \\1:
        // restore stack
        \\add $16, %rsp
        \\iretq
        :
        : [kcode] "i" (gdt.kernel_code),
    );
}
