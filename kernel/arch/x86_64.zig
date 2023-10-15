pub usingnamespace @import("x86_64/x86_64.zig");
pub const gdt = @import("x86_64/gdt.zig");
pub const idt = @import("x86_64/idt.zig");
pub const cpu = @import("x86_64/cpu.zig");

pub const Context = idt.Context;

pub fn init() void {
    gdt.init();
    idt.init();
}
