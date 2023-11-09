const std = @import("std");
const root = @import("root");
const vfs = root.vfs;

const Null = struct {
    const vtable: vfs.Node.VTable = .{
        .open = open,
        .close = close,
        .read = read,
        .write = write,
    };

    fn open(_: *vfs.Node, _: u64) vfs.OpenError!void {}

    fn close(_: *vfs.Node) void {}

    fn read(_: *vfs.Node, _: []u8, _: std.os.off_t) vfs.ReadError!usize {
        return 0;
    }

    fn write(_: *vfs.Node, buf: []const u8, _: std.os.off_t) vfs.WriteError!usize {
        return buf.len;
    }

    fn init() *vfs.Node {
        // 0o666 = std.fs.File.default_mode
        return vfs.Node.init(&vtable, "null", undefined, 0o666 | std.os.S.IFCHR) catch unreachable;
    }
};

const Zero = struct {
    const vtable: vfs.Node.VTable = .{
        .open = open,
        .close = close,
        .read = read,
        .write = write,
    };

    fn open(_: *vfs.Node, _: u64) vfs.OpenError!void {}

    fn close(_: *vfs.Node) void {}

    fn read(_: *vfs.Node, buf: []u8, _: std.os.off_t) vfs.ReadError!usize {
        @memset(buf, 0);
        return buf.len;
    }

    fn write(_: *vfs.Node, buf: []const u8, _: std.os.off_t) vfs.WriteError!usize {
        return buf.len;
    }

    fn init() *vfs.Node {
        return vfs.Node.init(&vtable, "zero", undefined, 0o666 | std.os.S.IFCHR) catch unreachable;
    }
};

pub fn init() void {
    _ = vfs.mount("/dev/null", Null.init()) catch unreachable;
    _ = vfs.mount("/dev/zero", Zero.init()) catch unreachable;
}
