pub const arch = @import("builtin").target.cpu.arch;
pub const endian = arch.endian();

pub usingnamespace switch (arch) {
    .x86_64 => @import("arch/x86_64.zig"),
    .riscv64 => @import("arch/riscv64.zig"),
    .aarch64 => @import("arch/aarch64.zig"),
    else => @compileError("Unsupported architecture: " ++ @tagName(arch)),
};
