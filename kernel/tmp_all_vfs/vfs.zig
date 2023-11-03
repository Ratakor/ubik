const std = @import("std");
const os = std.os; // TODO: replace std.os.* with os.*
const root = @import("root");
const SpinLock = root.SpinLock;
const tmpfs = @import("fs/tmpfs.zig");
const initramfs = @import("fs/initramfs.zig");
const isAbsolute = std.fs.path.isAbsolute;

// TODO: rename VNode to Node
// TODO: flags and offset as usize?
// TODO: move to ../servers/vfs/vfs.zig

const AllocatorError = std.mem.Allocator.Error;
pub const OpenError = std.os.OpenError || AllocatorError;
pub const ReadError = std.os.ReadError || AllocatorError;
pub const ReadDirError = ReadError || error{IsNotDir};
pub const WriteError = std.os.WriteError || AllocatorError;
pub const InsertError = std.os.MakeDirError || AllocatorError;
pub const IoctlError = AllocatorError; // TODO
pub const StatError = std.os.FStatAtError || AllocatorError;

// TODO
pub const FileDescriptor = struct {
    refcount: usize,
    offset: isize,
    flags: i32,
    lock: SpinLock = .{}, // TODO remove lock in VNode
    node: *VNode,
};

pub const VNode = struct {
    vtable: *const VTable,
    mountpoint: ?*VNode = null,
    kind: Kind,
    filesystem: ?*FileSystem = null, // TODO: nullable?
    name: []const u8, // TODO: zero terminated? + const?
    parent: ?*VNode = null,
    // children: std.AutoHashMapUnmanaged(usize, *VNode), // TODO <- use this instead of directory (string(array)hashmap?)
    symlink_target: ?[]const u8 = null, // TODO: const?
    inode: u64,
    lock: SpinLock = .{},

    pub const VTable = struct {
        open: ?*const fn (self: *VNode, name: []const u8, flags: u64) OpenError!*VNode = null,
        close: ?*const fn (self: *VNode) void = null,
        read: ?*const fn (self: *VNode, buf: []u8, offset: usize, flags: usize) ReadError!usize = null,
        readDir: ?*const fn (self: *VNode, buf: []u8, offset: *usize) ReadDirError!usize = null,
        write: ?*const fn (self: *VNode, buf: []const u8, offset: usize, flags: usize) WriteError!usize = null,
        insert: ?*const fn (self: *VNode, new_child: *VNode) InsertError!void = null, // TODO: rename mkdir?
        ioctl: ?*const fn (self: *VNode, request: u64, arg: u64) IoctlError!u64 = null,
        stat: ?*const fn (self: *VNode, buf: *std.os.Stat) StatError!void = null,
    };

    /// https://en.wikipedia.org/wiki/Unix_file_types
    pub const Kind = enum(u64) {
        const DT = std.os.DT;

        unknown = DT.UNKNOWN,
        file = DT.REG,
        directory = DT.DIR,
        symlink = DT.LNK,
        fifo = DT.FIFO,
        socket = DT.SOCK,
        device_block = DT.BLK,
        device_character = DT.CHR,
    };

    // TODO
    pub fn init(fs: ?*FileSystem, parent: ?*VNode, name: []const u8, dir: bool) !*VNode {
        const vnode = try root.allocator.create(VNode);
        errdefer root.allocator.destroy(vnode);
        vnode.name = try root.allocator.dupeZ(u8, name);
        vnode.parent = parent;
        vnode.filesystem = fs;
        vnode.inode = 0;
        vnode.lock = .{};

        if (dir) {
            vnode.children = .{};
            // try vnode.children.ensureTotalCapacity(root.allocator, 256); // TODO
        }

        @compileError("not implemented");
        // return vnode;
    }

    pub fn open(self: *VNode, name: []const u8, flags: usize) !*VNode {
        if (self.vtable.open) |func| {
            return func(self, name, flags);
        } else {
            return error.NotImplemented; // TODO
        }
    }

    pub fn close(self: *VNode) void {
        if (self.vtable.close) |func| {
            func(self);
        }
    }

    pub fn read(self: *VNode, buf: []u8, offset: usize, flags: usize) !usize {
        if (self.vtable.read) |func| {
            return func(self, buf, offset, flags);
        } else if (self.kind == .symlink) {
            return error.NotImplemented; // TODO
            // const read_len = @min(buf.len, self.symlink_target.?.len);
            // @memcpy(buf[0..read_len], self.symlink_target.?);
            // return read_len;

        } else {
            return error.NotImplemented; // TODO
        }
    }

    pub fn write(self: *VNode, buf: []const u8, offset: usize, flags: usize) !usize {
        if (self.vtable.write) |func| {
            return func(self, buf, offset, flags);
        } else if (self.kind == .symlink) {
            return WriteError.NotOpenForWriting;
        } else {
            return error.NotImplemented;
        }
    }

    // TODO: other func
    // TODO: writer/reader
    // TODO: mount
};

pub const FileSystem = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        createFile: *const fn (self: *FileSystem) AllocatorError!*VNode,
        createDir: *const fn (self: *FileSystem) AllocatorError!*VNode,
        createSymlink: *const fn (self: *FileSystem, target: []const u8) AllocatorError!*VNode,
        allocInode: *const fn (self: *FileSystem) u64,
    };

    pub fn createFile(self: *FileSystem, name: []const u8) !*VNode {
        const name_dup = try root.allocator.dupe(u8, name);
        errdefer root.allocator.free(name_dup);
        const file = try self.vtable.createFile(self, name);
        file.name = name_dup;
        return file;
    }

    pub fn createDir(self: *FileSystem, name: []const u8) !*VNode {
        const name_dup = try root.allocator.dupe(u8, name);
        errdefer root.allocator.free(name_dup);
        const dir = try self.vtable.createDir(self, name);
        dir.name = name_dup;
        return dir;
    }

    pub fn createSymlink(self: *FileSystem, name: []const u8, target: []const u8) !*VNode {
        const symlink = try self.vtable.createSymlink(self, name, target);
        symlink.name = try root.allocator.dupe(u8, name);
        return symlink;
    }
};

pub var root_vnode: *VNode = undefined;

pub fn init() void {
    root_vnode = tmpfs.init("", null) catch unreachable;
    // TODO: map limine modules as file <- initramfs
    initramfs.init();
}

fn resolve(cwd: ?*VNode, path: []const u8, flags: usize) (OpenError || InsertError)!*VNode {
    std.debug.assert(path.len != 0); //if (path.len == 0) return;
    if (cwd == null) {
        std.debug.assert(isAbsolute(path));
        return resolve(root_vnode, path, flags);
    }

    var next = if (isAbsolute(path)) root_vnode else cwd.?;
    var iter = std.mem.split(u8, path, std.fs.path.sep_str);

    while (iter.next()) |component| {
        var next_vnode: *VNode = undefined;

        if (component.len == 0 or std.mem.eql(u8, component, ".")) {
            continue;
        } else if (std.mem.eql(u8, component, "..")) {
            next_vnode = next.parent orelse next_vnode; // TODO
        } else {
            next_vnode = next.open(component, 0) catch |err| switch (err) {
                error.FileNotFound => blk: {
                    if (flags & std.os.O.CREAT == 0) return error.FileNotFound;

                    const fs = next; // TODO
                    const vnode = if (flags & std.os.O.DIRECTORY != 0 or iter.rest().len > 0)
                        try fs.createDir(component)
                    else
                        try fs.createFile(component);
                    try next.insert(vnode);
                    break :blk vnode;
                },
                else => |e| return e,
            };
        }

        if (flags & std.os.O.NOFOLLOW == 0 and next_vnode.kind == .symlink) {
            const old_vnode = next_vnode;
            const target = next_vnode.symlink_target.?;
            // TODO: check if isAbsolute?
            next_vnode = try resolve(if (isAbsolute(target)) null else next_vnode.parent, target, 0);
            if (next_vnode == old_vnode) return error.SymLinkLoop;
        }

        next = next_vnode;
    }

    return next;
}
