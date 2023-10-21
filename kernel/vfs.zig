const std = @import("std");
const root = @import("root");

pub const Node = struct {
    mountpoint: *Node,
    redir: *Node,
    // resource: *Resource,
    filesystem: ?*FileSystem,
    name: [:0]u8,
    parent: ?*Node,
    children: std.AutoHashMapUnmanaged(usize, *Node), // TODO
    symlink_target: []u8,
    populated: bool,

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
};

pub const FileSystem = struct {
    // TODO
};

// TODO: rename
pub var _root: *Node = undefined;

pub fn init() void {
    _root = Node.init(null, null, "", false) catch unreachable;
    // TODO filesystems
}
