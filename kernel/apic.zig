const vmm = @import("vmm.zig");

fn read(addr: u32, reg: u32) u32 {
    const base: [*]volatile u32 = @ptrFromInt(addr + vmm.higher_half);
    base[0] = reg;
    return base[4];
}

fn write(addr: u32, reg: u32, value: u32) void {
    const base: [*]volatile u32 = @ptrFromInt(addr + vmm.higher_half);
    base[0] = reg;
    base[4] = value;
}
