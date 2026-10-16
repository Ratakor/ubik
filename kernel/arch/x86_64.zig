const x86 = @import("x86_64/x86_64.zig");

pub const RFlags = x86.RFlags;
pub const MSR = x86.MSR;
pub const CpuID = x86.CpuID;
pub const halt = x86.halt;
pub const disableInterrupts = x86.disableInterrupts;
pub const enableInterrupts = x86.enableInterrupts;
pub const interruptState = x86.interruptState;
pub const toggleInterrupts = x86.toggleInterrupts;
pub const out = x86.out;
pub const in = x86.in;
pub const readRegister = x86.readRegister;
pub const writeRegister = x86.writeRegister;
pub const cpuid = x86.cpuid;
pub const rdmsr = x86.rdmsr;
pub const wrmsr = x86.wrmsr;
pub const wrxcr = x86.wrxcr;
pub const xsave = x86.xsave;
pub const xrstor = x86.xrstor;
pub const fxsave = x86.fxsave;
pub const fxrstor = x86.fxrstor;
pub const rdseed = x86.rdseed;
pub const rdrand = x86.rdrand;
pub const invlpg = x86.invlpg;
pub const gdt = @import("x86_64/gdt.zig");
pub const idt = @import("x86_64/idt.zig");
pub const apic = @import("x86_64/apic.zig");
pub const cpu = @import("x86_64/cpu.zig");
pub const pit = @import("x86_64/pit.zig");
pub const Context = idt.Context;
const mem = @import("x86_64/mem.zig");

comptime {
    @export(&mem.cpy, .{ .name = "memcpy", .linkage = .weak, .visibility = .default });
    @export(&mem.set, .{ .name = "memset", .linkage = .weak, .visibility = .default });
}

pub fn init() void {
    gdt.init();
    idt.init();

    // disable PIC
    @This().out(u8, 0xa1, 0xff);
    @This().out(u8, 0x21, 0xff);
}
