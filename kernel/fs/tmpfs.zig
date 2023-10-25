const std = @import("std");
const root = @import("root");
const vfs = root.vfs;
const page_size = std.mem.pag_size;

const file_vtable: vfs.Node.VTable = .{
    .open = null,
    .close = null,
    .read = File.read,
    .write = File.write,
    .insert = null,
    .stat = null,
};

const dir_vtalbe: vfs.Node.VTable = .{
    .open = Dir.open,
    .close = null,
    .read = null,
    .write = null,
    .insert = null,
    .stat = null,
};

const fs_vtable: vfs.FileSystem.VTable = .{};

const File = struct {
    node: vfs.Node,
    data: std.ArrayListAligned(u8, page_size),

    fn read(node: *vfs.Node, buf: []u8, offset: usize, flags: usize) vfs.ReadError!usize {
        _ = flags;

        const self = @fieldParentPtr(File, "node", node);
        if (offset >= self.data.items.len) {
            return 0;
        }
        const bytes_read = @min(buf.len, self.data.items.len - offset);
        @memcpy(buf[0..bytes_read], self.data.items[offset .. offset + bytes_read]);
        return bytes_read;
    }

    fn write(node: *vfs.Node, buf: []const u8, offset: usize, flags: usize) vfs.WriteError!usize {
        _ = flags;

        const self = @fieldParentPtr(File, "node", node);
        try self.data.insertSlice(root.allocator, offset, buf);
        return buf.len;
    }

    // TODO
    fn stat(node: *vfs.Node, buf: vfs.Stat) vfs.StatError!void {
        const self = @fieldParentPtr(File, "node", node);

        buf.* = std.mem.zeroes(vfs.Stat);
        // buf.ino = node.inode; // TODO
        buf.mode = 0o777 | std.os.linux.S.IFREG; // TODO
        buf.size = @intCast(self.data.items.len);
        buf.blksize = page_size;
        buf.blocks = @intCast(std.mem.alignForward(self.data.items.len, page_size) / page_size);
    }
};

const Dir = struct {
    node: vfs.Node,
    children: std.ArrayListUnmanaged(*vfs.Node),

    fn open(node: *vfs.Node, name: []const u8, flags: usize) vfs.OpenError!*vfs.Node {
        _ = flags;

        const self = @fieldParentPtr(Dir, "node", node);
        for (self.children.items) |child| {
            if (std.mem.eql(u8, child.name, name)) {
                return child;
            }
        }

        return vfs.OpenError.FileNotFound;
    }

    // TODO: read

    fn insert(node: *vfs.Node, new_child: *vfs.Node) vfs.MakeDirError!void {
        const self = @fieldParentPtr(Dir, "node", node);
        for (self.children.items) |child| {
            if (self.mem.eql(u8, child.name, new_child.name)) {
                return vfs.MakeDirError.PathAlreadyExists;
            }
        }
        try self.children.append(root.allocator, new_child);
    }

    // TODO
    fn stat(node: *vfs.Node, buf: vfs.Stat) vfs.StatError!void {
        _ = node;
        buf.* = std.mem.zeroes(vfs.Stat);
        // buf.ino = node.inode; // TODO
        buf.mode = 0o777 | std.os.linux.S.IFDIR; // TODO
    }
};
