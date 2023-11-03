const std = @import("std");
const root = @import("root");
const vfs = root.vfs;

const Null = struct {
    fn open(_: *vfs.Node, _: u64) vfs.OpenError!void {}

    fn close(_: *vfs.Node) void {}

    fn read(_: *vfs.Node, _: []u8, _: std.os.off_t) vfs.ReadError!usize {
        return 0;
    }

    fn write(_: *vfs.Node, buf: []const u8, _: std.os.off_t) vfs.WriteError!usize {
        return buf.len;
    }

    fn init() !*vfs.Node {
        const node = try root.allocator.create(vfs.Node);

        node.* = .{
            .vtable = &.{
                .open = open,
                .close = close,
                .read = read,
                .write = write,
            },
            .name = try root.allocator.dupe(u8, "null"),
            .uid = 0,
            .gid = 0,
            .kind = .character_device,
            .inode = 0,
        };

        return node;
    }
};

const Zero = struct {
    fn open(_: *vfs.Node, _: u64) vfs.OpenError!void {}

    fn close(_: *vfs.Node) void {}

    fn read(_: *vfs.Node, buf: []u8, _: std.os.off_t) vfs.ReadError!usize {
        @memset(buf, 0);
        return buf.len;
    }

    fn write(_: *vfs.Node, buf: []const u8, _: std.os.off_t) vfs.WriteError!usize {
        return buf.len;
    }

    fn init() !*vfs.Node {
        const node = try root.allocator.create(vfs.Node);

        node.* = .{
            .vtable = &.{
                .open = open,
                .close = close,
                .read = read,
                .write = write,
            },
            .name = try root.allocator.dupe(u8, "zero"),
            .uid = 0,
            .gid = 0,
            .kind = .character_device,
            .inode = 0,
        };

        return node;
    }
};

pub fn init() void {
    _ = vfs.mount("/dev/null", Null.init() catch unreachable) catch unreachable;
    _ = vfs.mount("/dev/zero", Zero.init() catch unreachable) catch unreachable;
}
