const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Tree(comptime T: type) type {
    return struct {
        pub const Node = struct {
            value: T,
            children: std.ArrayListUnmanaged(*Node) = .{},
            parent: ?*Node = null,

            pub fn init(allocator: Allocator, value: T) Allocator.Error!*Node {
                const node = try allocator.create(Node);
                node.* = .{ .value = value };
                return node;
            }

            // TODO: add a comptime bool for if to free value?
            /// Free a node, its children and their values
            pub fn deinit(self: *Node, allocator: Allocator) void {
                for (self.children.items) |child| {
                    child.deinit(allocator);
                }

                if (comptime @typeInfo(T) == .Pointer) {
                    switch (comptime @typeInfo(T).Size) {
                        .One => allocator.destroy(self.value),
                        .Slice => allocator.free(self.value),
                        .Many, .C => @compileError("TODO"),
                    }
                }

                self.children.deinit(allocator);
                allocator.destroy(self);
            }

            // TODO: useless? + very slow
            pub fn findParent(self: *Node, maybe_parent: *Node) ?*Node {
                return for (maybe_parent.children.items) |child| {
                    if (child == self) {
                        break maybe_parent;
                    }
                    if (self.findParent(child)) |parent| {
                        break parent;
                    }
                } else null;
            }

            // TODO: very slow
            pub fn find(self: *Node, value: T) ?*Node {
                if (std.meta.eql(self.value, value)) {
                    return self;
                }

                return for (self.children.items) |child| {
                    if (child.find(value)) |node| {
                        break node;
                    }
                } else null;
            }
        };

        const Self = @This();

        count: usize,
        root: ?*Node,
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{
                .count = 0,
                .root = null,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.root) |root| {
                root.deinit(self.allocator);
            }
        }

        pub fn setRoot(self: *Self, value: T) Allocator.Error!void {
            self.root = try Node.init(self.allocator, value);
            self.count = 1;
        }

        pub fn insertNode(self: *Self, parent: *Node, node: *Node) Allocator.Error!void {
            try parent.children.append(self.allocator, node);
            node.parent = parent;
            self.count += 1;
        }

        pub fn insert(self: *Self, parent: *Node, value: T) Allocator.Error!*Node {
            const node = try Node.init(self.allocator, value);
            try self.insertNode(parent, node);
            return node;
        }

        // TODO: useless?
        pub fn findParent(self: *Self, node: *Node) ?*Node {
            return if (self.root) |root| node.findParent(root) else null;
        }

        // TODO: rename
        pub fn removeBranchWithParent(self: *Self, parent: *Node, node: *Node) void {
            self.count -= node.children.items.len + 1;
            parent.children.swapRemove(std.mem.indexOfScalar(
                usize,
                @ptrCast(parent.children),
                @intFromPtr(node),
            ));
            node.deinit(self.allocator);
        }

        // TODO: This is terrible, use the cleaner one with a panic
        pub fn removeBranch(self: *Self, parent: ?*Node, node: *Node) void {
            const p = if (parent) |p| blk: {
                if (node.parent) |np| {
                    std.debug.assert(p == np);
                }
                break :blk p;
            } else if (node.parent) |p| blk: {
                break :blk p;
            } else if (self.root) |p| blk: {
                break :blk p;
            } else {
                node.deinit(self.allocator);
                return;
            };

            self.count -= node.children.items.len + 1;
            p.children.swapRemove(std.mem.indexOfScalar(
                usize,
                @ptrCast(p.children),
                @intFromPtr(node),
            ) orelse unreachable); // TODO
            node.deinit(self.allocator);
        }

        // pub fn removeBranch(self: *Self, node: *Node) void {
        //     if (node.parent) |parent| {
        //         self.count -= node.children.items.len + 1;
        //         parent.children.swapRemove(std.mem.indexOfScalar(
        //                 usize,
        //                 @ptrCast(parent.children),
        //                 @intFromPtr(node),
        //         ) orelse unreachable); // TODO
        //         node.deinit(self.allocator);
        //     } else {
        //         // TODO
        //         @panic("call to removeBranch with a node without parent");
        //     }
        // }

        pub fn removeNode(self: *Self, node: *Node, comptime use_root: bool) Allocator.Error!void {
            if (node.parent) |parent| {
                self.count -= 1;
                parent.children.swapRemove(std.mem.indexOfScalar(
                    usize,
                    @ptrCast(parent.children),
                    @intFromPtr(node),
                ) orelse unreachable); // TODO
                for (node.children.items) |child| {
                    child.parent = if (comptime use_root) self.root else parent;
                }
                if (comptime use_root) {
                    try self.root.?.children.appendSlice(self.allocator, node.children.items);
                } else {
                    try parent.children.appendSlice(self.allocator, node.children.items);
                }

                node.children.deinit(self.allocator);
                self.allocator.destroy(node);
            }
        }

        pub fn find(self: *Self, value: T) ?*Node {
            return if (self.root) |root| root.find(value) else null;
        }
    };
}
