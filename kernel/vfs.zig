const std = @import("std");
const root = @import("root");

pub const OpenError = std.os.OpenError;
pub const ReadError = std.os.ReadError;
pub const WriteError = std.os.WriteError;
pub const MakeDirError = std.os.MakeDirError;
// pub const IoctlError = // TODO
pub const StatError = std.os.FStatAtError;

pub const Stat = std.os.linux.Stat;

pub const Node = struct {
    vtable: *const VTable,
    mountpoint: ?*Node,
    kind: Kind,
    // redir: *Node,
    // resource: *Resource,
    filesystem: ?*FileSystem,
    name: [:0]u8, // TODO: zero terminated?
    parent: ?*Node,
    children: std.AutoHashMapUnmanaged(usize, *Node), // TODO
    symlink_target: ?[]u8,

    // TODO: not nullable
    pub const VTable = struct {
        open: ?*const fn (self: *Node, name: []const u8, flags: usize) OpenError!*Node,
        close: ?*const fn (self: *Node) void,
        read: ?*const fn (self: *Node, buf: []u8, offset: usize, flags: usize) ReadError!usize,
        // read_dir: ?*const fn (self: *Node, buf: []u8, offset: *usize) (ReadError || error.IsNotDir)!usize, // TODO
        write: ?*const fn (self: *Node, buf: []const u8, offset: usize, flags: usize) WriteError!usize,
        insert: ?*const fn (self: *Node, new_child: *Node) MakeDirError!void, // TODO: rename mkdir?
        // ioctl: ?*const fn (self: *Node, request: u64, arg: u64) IoctlError!u64, // TODO
        stat: ?*const fn (self: *Node, buf: *Stat) StatError!void,
    };

    pub const Kind = enum {
        file,
        directory,
        symlink,
        socket,
        fifo,
        block_device,
        character_device,
    };

    pub fn init(fs: ?*FileSystem, parent: ?*Node, name: []const u8, dir: bool) !*Node {
        const node = try root.allocator.create(Node);
        errdefer root.allocator.destroy(node);
        node.name = try root.allocator.dupeZ(u8, name);
        node.parent = parent;
        node.filesystem = fs;

        if (dir) {
            node.children = .{};
            // try node.children.ensureTotalCapacity(root.allocator, 256); // TODO
        }

        return node;
    }

    pub fn open(self: *Node, name: []const u8, flags: usize) !*Node {
        if (self.vtable.open) |func| {
            return func(self, name, flags);
        } else {
            return error.NotImplemented; // TODO
        }
    }

    pub fn close(self: *Node) void {
        if (self.vtable.close) |func| {
            func(self);
        }
    }

    // TODO
};

pub const FileSystem = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        // TODO: create, symlink, etc
    };
};

// TODO: rename
pub var _root: *Node = undefined;

pub fn init() void {
    _root = Node.init(null, null, "", false) catch unreachable;
    // TODO filesystems
}
