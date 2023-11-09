const std = @import("std");
const root = @import("root");
const vfs = root.vfs;
const arch = root.arch;

const vtable = vfs.Node.VTable{
    .read = read,
    .write = write,
};

pub fn init() void {
    const node = vfs.Node.init(&vtable, "port", undefined, 0o640 | std.os.S.IFBLK) catch unreachable;
    vfs.mount("/dev/port", node) catch unreachable;
}

fn read(node: *vfs.Node, buf: []u8, offset: std.os.off_t) vfs.ReadError!usize {
    _ = node;

    const port: u16 = @intCast(offset);
    switch (buf.len) {
        @sizeOf(u8) => buf[0] = arch.in(u8, port),
        @sizeOf(u16) => @as(*u16, @ptrCast(@alignCast(buf.ptr))).* = arch.in(u16, port),
        @sizeOf(u32) => @as(*u32, @ptrCast(@alignCast(buf.ptr))).* = arch.in(u32, port),
        else => for (buf, 0..) |*byte, i| {
            byte.* = arch.in(u8, @intCast(port + i));
        },
    }

    return buf.len;
}

fn write(node: *vfs.Node, buf: []const u8, offset: std.os.off_t) vfs.WriteError!usize {
    _ = node;

    const port: u16 = @intCast(offset);
    switch (buf.len) {
        @sizeOf(u8) => arch.out(u8, port, buf[0]),
        @sizeOf(u16) => arch.out(u16, port, std.mem.readInt(u16, buf[0..@sizeOf(u16)], arch.endian)),
        @sizeOf(u32) => arch.out(u32, port, std.mem.readInt(u32, buf[0..@sizeOf(u32)], arch.endian)),
        else => for (buf, 0..) |byte, i| {
            arch.out(u8, @intCast(port + i), byte);
        },
    }

    return buf.len;
}
