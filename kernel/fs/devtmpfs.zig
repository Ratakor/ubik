const std = @import("std");
const root = @import("root");
const vfs = root.vfs;

const Device = struct {
    node: vfs.Node,
    data: std.ArrayListUnmanaged(u8) = .{},

    pub fn init(mode: std.os.mode_t) *Device {
        const device = try root.allocator.create(Device);
        device.* = .{ .node = try vfs.Node.init("", null, null) }; // TODO

        if (std.os.S.ISREG(mode)) {
            // resource->capacity = 4096;
            // resource->data = alloc(resource->capacity);
            // resource->can_mmap = true;
        }

        // TODO vtable is global
        // device.node.vtable.read = devtmpfs_resource_read;
        // device.node.vtable.write = devtmpfs_resource_write;
        // device.node.vtable.mmap = devtmpfs_resource_mmap;
        // device.node.vtable.msync = devtmpfs_resource_msync;
        // device.node.vtable.truncate = devtmpfs_truncate;

        device.node.stat.size = 0;
        device.node.stat.blocks = 0;
        device.node.stat.blksize = 512;
        // TODO
        // device.node.stat.dev = this->dev_id;
        // device.node.stat.ino = this->inode_counter++;
        device.node.stat.mode = mode;
        device.node.stat.nlink = 1;
        // TODO set in Node.init;
        // resource->stat.st_atim = time_realtime;
        // resource->stat.st_ctim = time_realtime;
        // resource->stat.st_mtim = time_realtime;

        return device;
    }

    fn read(node: *vfs.Node, buf: []u8, offset: std.os.off_t) vfs.ReadError!usize {
        const self = @fieldParentPtr(Device, "node", node);
        if (offset >= self.data.items.len) {
            return 0;
        }

        const bytes_read = @min(buf.len, self.data.items.len - offset);
        const u_offset: usize = @intCast(offset);
        @memcpy(buf[0..bytes_read], self.data.items[u_offset .. u_offset + bytes_read]);
        return bytes_read;
    }

    fn write(node: *vfs.Node, buf: []const u8, offset: std.os.off_t) vfs.WriteError!usize {
        const self = @fieldParentPtr(Device, "node", node);
        try self.data.insertSlice(root.allocator, @intCast(offset), buf);
        return buf.len;
    }

    fn truncate(node: *vfs.Node, length: usize) vfs.DefaultError!void {
        const self = @fieldParentPtr(Device, "node", node);
        try self.data.resize(root.allocator, length);
    }

    // stat
    // mmap
};

// TODO: not a struct just a vtable and global dev_id/inode_counter
const FileSystem = struct {
    fs: *vfs.FileSystem,
    dev_id: std.os.ino_t,
    inode_counter: std.os.ino_t,

    fn create(fs: *vfs.FileSystem, parent: *vfs.Node, name: []const u8, mode: std.os.mode_t) !*vfs.Node {
        _ = mode;
        _ = name;
        _ = parent;
        const self = @fieldParentPtr(FileSystem, "fs", fs);
        _ = self;
        // const new_node = try vfs.Node.init(fs, parent, name);
        // return Device.init(mode);
    }

    fn symlink(fs: *vfs.FileSystem, parent: *vfs.Node, name: []const u8, target: []const u8) !*vfs.Node {
        _ = target;
        _ = name;
        _ = parent;
        _ = fs;
        // symlink_target
        // const self = @fieldParentPtr(FileSystem, "fs", fs);
        // const new_node = try vfs.Node.init(fs, parent, name);
        // return Device.init(0o777 | std.os.S.IFLNK);
    }
};

var root_node: *vfs.Node = undefined;

// TODO
fn mount(parent: *vfs.Node, name: []const u8, source: *vfs.Node) *vfs.Node {
    _ = source;
    _ = name;
    _ = parent;
    return root_node;
}

pub fn init() void {
    // const root_node = FileSystem.create({}, null, "", 0o755 | std.os.S.IFDIR) catch unreachable;
    vfs.registerFileSystem("devtmpfs", mount);
}

pub fn addDevice(device: *vfs.Node, name: []const u8) !void {
    _ = name;
    _ = device;
    // gop on devtmpfs

}
