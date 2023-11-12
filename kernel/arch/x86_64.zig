pub usingnamespace @import("x86_64/x86_64.zig");
pub const gdt = @import("x86_64/gdt.zig");
pub const idt = @import("x86_64/idt.zig");
pub const apic = @import("x86_64/apic.zig");
pub const cpu = @import("x86_64/cpu.zig");
pub const pit = @import("x86_64/pit.zig");
pub const Context = idt.Context;
const mem = @import("x86_64/mem.zig");

comptime {
    @export(mem.cpy, .{ .name = "memcpy", .linkage = .Weak, .visibility = .default });
    @export(mem.set, .{ .name = "memset", .linkage = .Weak, .visibility = .default });
}

pub fn init() void {
    gdt.init();
    idt.init();

    // disable PIC
    @This().out(u8, 0xa1, 0xff);
    @This().out(u8, 0x21, 0xff);
}
