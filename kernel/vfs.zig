const std = @import("std");
const os = std.os;
const root = @import("root");
const time = @import("time.zig");
const SpinLock = root.SpinLock;
const DirectoryEntry = root.os.system.DirectoryEntry;
const log = std.log.scoped(.vfs);

// TODO: not sure about these errors
pub const DefaultError = std.mem.Allocator.Error || os.UnexpectedError;
pub const OpenError = os.OpenError || DefaultError;
pub const ReadError = os.ReadError || DefaultError;
pub const ReadDirError = ReadError || error{IsNotDir};
pub const ReadLinkError = ReadError || error{IsNotLink};
pub const WriteError = os.WriteError || DefaultError;
pub const CreateError = os.MakeDirError || DefaultError;
pub const StatError = os.FStatError || DefaultError;

// TODO: rename VNode?
pub const Node = struct {
    vtable: *const VTable,
    name: []u8,
    kind: Kind,
    stat: os.Stat,
    open_flags: u64, // TODO: read/write/append, ...
    mount_point: ?*Node, // TODO: symlinks <- no it's a different thing
    refcount: usize,
    lock: SpinLock = .{}, // TODO: use
    // can_mmap: bool, // TODO
    // status: i32, // TODO
    // event: Event, // TODO
    filesystem: ?*FileSystem, // TODO + nullable? + in VTable?
    parent: ?*Node, // TODO: nullable?
    children: std.StringHashMapUnmanaged(*Node) = .{},
    // symlink_target: ?[]u8, // TODO
    // redirection: ?*Node // TODO

    pub const VTable = struct {
        open: *const fn (self: *Node, flags: u64) OpenError!void = @ptrCast(&stubFn),
        close: *const fn (self: *Node) void = @ptrCast(&stubFn),
        read: *const fn (self: *Node, buf: []u8, offset: os.off_t) ReadError!usize = @ptrCast(&stubFn),
        readLink: *const fn (self: *Node, buf: []u8) ReadLinkError!usize = @ptrCast(&stubFn),
        readDir: *const fn (self: *Node, index: usize) ReadDirError!*DirectoryEntry = @ptrCast(&stubFn),
        write: *const fn (self: *Node, buf: []const u8, offset: os.off_t) WriteError!usize = @ptrCast(&stubFn),
        ioctl: *const fn (self: *Node, request: u64, arg: *anyopaque) DefaultError!u64 = @ptrCast(&stubFn), // return u64?
        chmod: *const fn (self: *Node, mode: os.mode_t) DefaultError!void = &stubChmod, // @ptrCast(&stubFn), // TODO: error
        chown: *const fn (self: *Node, uid: os.uid_t, gid: os.gid_t) DefaultError!void = @ptrCast(&stubFn), // TODO: error
        truncate: *const fn (self: *Node, length: usize) DefaultError!void = @ptrCast(&stubFn), // TODO: error
        unlink: *const fn (self: *Node, name: []const u8) DefaultError!void = @ptrCast(&stubFn), // TODO: error
        stat: *const fn (self: *Node, statbuf: *os.Stat) StatError!void = @ptrCast(&stubFn),

        pub const stub: VTable = .{};

        fn stubChmod(self: *Node, mode: os.mode_t) DefaultError!void {
            self.stat.mode &= ~@as(os.mode_t, 0o777);
            self.stat.mode |= mode & 0o777;
        }

        fn stubFn() !void {
            return error.Unexpected;
        }
    };

    pub const Kind = enum(u8) {
        block_device = os.DT.BLK,
        character_device = os.DT.CHR,
        directory = os.DT.DIR,
        named_pipe = os.DT.FIFO,
        symlink = os.DT.LNK,
        file = os.DT.REG,
        unix_domain_socket = os.DT.SOCK,
        whiteout = os.DT.WHT,
        unknown = os.DT.UNKNOWN,
    };

    pub const Stream = struct {
        node: *Node,
        offset: u64 = 0,

        pub const SeekError = error{};
        pub const GetSeekPosError = error{};

        pub const SeekableStream = std.io.SeekableStream(
            *Stream,
            SeekError,
            GetSeekPosError,
            Stream.seekTo,
            Stream.seekBy,
            Stream.getPosFn,
            Stream.getEndPosFn,
        );

        pub const Reader = std.io.Reader(*Stream, ReadError, Stream.read);

        fn seekTo(self: *Stream, offset: u64) SeekError!void {
            self.offset = offset;
        }

        fn seekBy(self: *Stream, offset: i64) SeekError!void {
            self.offset +%= @bitCast(offset);
        }

        fn getPosFn(self: *Stream) GetSeekPosError!u64 {
            return self.offset;
        }

        fn getEndPosFn(self: *Stream) GetSeekPosError!u64 {
            _ = self;
            return 0; // TODO
        }

        fn read(self: *Stream, buf: []u8) ReadError!usize {
            return self.node.read(buf, self.offset);
        }

        pub fn seekableStream(self: *Stream) SeekableStream {
            return .{ .context = self };
        }

        pub fn reader(self: *Stream) Reader {
            return .{ .context = self };
        }
    };

    pub fn init(name: []const u8, fs: ?*FileSystem, parent: ?*Node) !*Node {
        const node = try root.allocator.create(Node);
        node.* = .{
            .vtable = undefined,
            .name = try root.allocator.dupe(u8, name),
            .kind = undefined,
            .stat = .{
                .dev = undefined,
                .ino = undefined,
                .mode = 0o666,
                .nlink = 0,
                .uid = 0,
                .gid = 0,
                .rdev = undefined,
                .size = undefined,
                .blksize = undefined,
                .blocks = undefined,
                .atim = time.realtime,
                .mtim = time.realtime,
                .ctim = time.realtime,
            },
            .open_flags = 0,
            .mount_point = null,
            .refcount = 0,
            .filesystem = fs,
            .parent = parent,
        };
        return node;
    }

    pub fn getEffectiveNode(self: *Node, follow_symlinks: bool) *Node {
        // if (self.redirection) |redirection| {
        //     return getEffectiveNode(redirection, follow_symlinks);
        // }
        if (self.mount_point) |mount_point| {
            return getEffectiveNode(mount_point, follow_symlinks);
        }
        if (follow_symlinks) {
            if (self.symlink_target) |symlink_target| {
                _ = symlink_target;
                // TODO
            }
        }
        return self;
    }

    // TODO
    pub fn open(self: *Node, flags: u64) OpenError!*Node {
        self.refcount += 1;
        return self.vtable.open(self, flags);
    }

    // TODO
    pub fn close(self: *Node) void {
        self.refcount -= 1;
        if (self.refcount == 0) {
            self.vtable.close(self);
            // TODO: Node.deinit(); ?
        }
    }

    pub inline fn read(self: *Node, buf: []u8, offset: os.off_t) ReadError!usize {
        // TODO check flags for open for reading + merge with readLink and readDir?
        return self.vtable.read(self, buf, offset);
    }

    pub inline fn readLink(self: *Node, buf: []u8) ReadLinkError!void {
        if (self.kind != .symlink) return error.IsNotLink;
        return self.vtable.readLink(self, buf);
    }

    pub inline fn readDir(self: *Node, index: usize) ReadDirError!*DirectoryEntry {
        if (self.kind != .directory) return error.IsNotDir;
        return self.vtable.readDir(self, index);
    }

    pub inline fn write(self: *Node, buf: []const u8, offset: os.off_t) WriteError!usize {
        // TODO check flags for open for writing
        return self.vtable.write(self, buf, offset);
    }

    pub inline fn ioctl(self: *Node, request: u64, arg: *anyopaque) DefaultError!u64 {
        return self.vtable.ioctl(self, request, arg);
    }

    pub inline fn chmod(self: *Node, mode: os.mode_t) DefaultError!void {
        return self.vtable.chmod(self, mode);
    }

    pub inline fn chown(self: *Node, uid: os.uid_t, gid: os.gid_t) DefaultError!void {
        return self.vtable.chown(self, uid, gid);
    }

    pub inline fn truncate(self: *Node) DefaultError!void {
        return self.vtable.truncate(self);
    }
};

// TODO
pub const FileSystem = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        // TODO: merge createFile and makeDir?
        createFile: *const fn (self: *FileSystem, parent: *Node, name: []const u8, mode: os.mode_t) CreateError!void,
        makeDir: *const fn (self: *FileSystem, parent: *Node, name: []const u8, mode: os.mode_t) CreateError!void,
        symlink: *const fn (self: *FileSystem, parent: *Node, name: []const u8, target: []const u8) CreateError!void,
    };

    // TODO
    // pub fn createFile(self: *FileSystem, name: []const u8) !*VNode {
    //     const name_dup = try root.allocator.dupe(u8, name);
    //     errdefer root.allocator.free(name_dup);
    //     const file = try self.vtable.createFile(self, name);
    //     file.name = name_dup;
    //     return file;
    // }

    // pub fn createDir(self: *FileSystem, name: []const u8) !*VNode {
    //     const name_dup = try root.allocator.dupe(u8, name);
    //     errdefer root.allocator.free(name_dup);
    //     const dir = try self.vtable.createDir(self, name);
    //     dir.name = name_dup;
    //     return dir;
    // }

    // pub fn createSymlink(self: *FileSystem, name: []const u8, target: []const u8) !*VNode {
    //     const symlink = try self.vtable.createSymlink(self, name, target);
    //     symlink.name = try root.allocator.dupe(u8, name);
    //     return symlink;
    // }
};

pub const FileDescriptor = struct {
    node: *Node,
    offset: os.off_t,
    // TODO: mode, lock, flags, refcount?
};

pub const MountFn = *const fn (parent: *Node, target: []const u8, source: *Node) CreateError!*Node;

var filesystems: std.StringHashMapUnmanaged(MountFn) = .{};
var root_node: *Node = undefined;
var vfs_lock: SpinLock = .{};

pub fn init() void {
    root_node = Node.init("", null, null) catch unreachable;
}

pub fn registerFileSystem(name: []const u8, mountFn: MountFn) !void {
    vfs_lock.lock();
    defer vfs_lock.unlock();

    const rv = try filesystems.getOrPut(root.allocator, name);
    std.debug.assert(rv.found_existing == false);
    rv.value_ptr.* = mountFn;
    log.info("registered filesystem `{s}`", .{name});
}

pub fn createFile(name: []const u8, mode: os.mode_t, comptime is_dir: bool) !void {
    _ = is_dir;
    _ = mode;
    _ = name;
    // TODO
}

pub fn symlink(name: []const u8, target: []const u8) !void {
    _ = target;
    _ = name;
    // TODO
}

pub fn unlink(name: []const u8) !void {
    _ = name;
    // TODO
}

fn makePath(path: []const u8, fs_name: []const u8) !*Node {
    if (!std.fs.path.isAbsolute(path)) return error.PathIsNotAbsolute;
    const fs = filesystems.get(fs_name) orelse return error.UnknownFileSystem;
    _ = fs;

    var node = root_node;
    var iter = std.mem.tokenizeScalar(u8, path, std.fs.path.sep);
    while (iter.next()) |component| {
        const gop = try node.children.getOrPut(root.allocator, component);
        if (gop.found_existing) {
            node = gop.value_ptr.*;
        } else {
            const new_node = try Node.init(); // TODO fs.create
            gop.value_ptr.* = new_node;
            node = new_node;
        }
    }
    return node;
}

// TODO: rework
const Path2Node = struct {
    target_parent: *Node,
    target: ?*Node,
    basename: []const u8,

    pub fn init(parent: *Node, path: []const u8) !Path2Node {
        const ask_for_dir = path[path.len - 1] == std.fs.path.sep; // TODO?

        var current_node = if (path[0] == std.fs.path.sep)
            root_node.getEffectiveNode(false)
        else
            // TODO: populate
            parent.getEffectiveNode(false);

        var iter = std.mem.tokenizeScalar(u8, path, std.fs.path.sep);
        while (iter.next()) |component| {
            current_node = current_node.getEffectiveNode(false);
            var next_node = current_node.children.get(component) orelse {
                _ = iter.peek() orelse return .{
                    .target_parent = current_node,
                    .target = null,
                    .basename = try root.allocator.dupe(u8, component),
                };
                return error.NodeNotFound;
            };
            next_node = next_node.getEffectiveNode(false);
            // TODO: populate

            _ = iter.peek() orelse {
                if (ask_for_dir and !os.S.ISDIR(next_node.mode)) {
                    return .{
                        .target_parent = current_node,
                        .target = null,
                        .basename = try root.allocator.dupe(u8, component),
                    };
                }
                return .{
                    .target_parent = current_node,
                    .target = next_node,
                    .basename = try root.allocator.dupe(u8, component),
                };
            };

            current_node = next_node;

            if (os.S.ISLNK(current_node.mode)) {
                // const r = try Path2Node.init(current_node.parent, current_node.symlink_target);
                // if (r.target) |target| {
                //     current_node = target;
                // } else {
                //     return error.bad; // TODO
                // }
            }

            if (!os.S.ISDIR(current_node.mode)) {
                return error.IsDir;
            }
        }
        unreachable;
    }
};

pub fn mount(parent: *Node, source: []const u8, target: []const u8, fs_name: []const u8) !void {
    _ = fs_name;
    _ = target;
    _ = source;
    _ = parent;
    vfs_lock.lock();
    defer vfs_lock.unlock();

    // TODO
}

// pub fn mount(path: []const u8, file: *Node) !*Node {
//     std.debug.assert(std.fs.path.isAbsolute(path));
//     std.debug.assert(file.mountpoint == null); // TODO

//     vfs_lock.lock();
//     defer vfs_lock.unlock();

//     file.refcount = -1;

//     var node = root_node;
//     var iter = std.mem.tokenizeScalar(u8, path, std.fs.path.sep);

//     // TODO: this is makePath, extract it?
//     while (iter.next()) |component| {
//         const gop = try node.children.getOrPut(root.allocator, component);
//         if (gop.found_existing) {
//             node = gop.value_ptr.*;
//         } else {
//             const new_node = try root.allocator.create(Node);
//             // const new_node = try Node.init(); // TODO
//             gop.value_ptr.* = new_node;
//             node = new_node;
//         }
//     }

//     // TODO: mountpoint?
//     // if (node.mountpoint) |_| {
//     //     log.warn("path {s} is already mounted!", .{path});
//     //     // TODO: return or throw err?
//     // }
//     file.mountpoint = node;

//     log.info("mounted `{s}` to `{s}`", .{ file.name, path });

//     return node;
// }

// TODO
// fn readDirMapper(self: *Node, index: usize) ReadDirError!*DirectoryEntry {
//     if (self.device) |device| {
//         const dev: *Tree.Node = @ptrCast(device);

//         if (index == 0) {
//             const dirent = try root.allocator.create(DirectoryEntry);
//             @memcpy(dirent.name[0..], ".");
//             dirent.ino = 0;
//             return dirent;
//         } else if (index == 1) {
//             const dirent = try root.allocator.create(DirectoryEntry);
//             @memcpy(dirent.name[0..], "..");
//             dirent.ino = 1;
//             return dirent;
//         }

//         index -= 2;
//         var i: usize = 0;
//         for (dev.children.items) |child| {
//             if (i == index) {
//                 const entry = child.value;
//                 const dirent = try root.allocator.create(DirectoryEntry);
//                 @memcpy(dirent, entry.name); // TODO
//                 dirent.ino = i;
//                 return dirent;
//             }
//             i += 1;
//         }
//     }

//     return null;
// }

// // TODO
// fn mapper() !*Node {
//     const node = try root.allocator.create(Node);
//     node.* = .{
//         .vtable = .{ .readDir = readDirMapper },
//         .mode = 0o555,
//         .kind = .directory,
//         .ctime = time.now(),
//         .mtime = time.now(),
//         .atime = time.now(),
//     };
//     return node;
// }

// TODO
// fn resolve(cwd: ?*VNode, path: []const u8, flags: usize) (OpenError || InsertError)!*VNode {
//     std.debug.assert(path.len != 0); //if (path.len == 0) return;
//     if (cwd == null) {
//         std.debug.assert(isAbsolute(path));
//         return resolve(root_vnode, path, flags);
//     }

//     var next = if (isAbsolute(path)) root_vnode else cwd.?;
//     var iter = std.mem.split(u8, path, std.fs.path.sep_str);

//     while (iter.next()) |component| {
//         var next_vnode: *VNode = undefined;

//         if (component.len == 0 or std.mem.eql(u8, component, ".")) {
//             continue;
//         } else if (std.mem.eql(u8, component, "..")) {
//             next_vnode = next.parent orelse next_vnode; // TODO
//         } else {
//             next_vnode = next.open(component, 0) catch |err| switch (err) {
//                 error.FileNotFound => blk: {
//                     if (flags & std.os.O.CREAT == 0) return error.FileNotFound;

//                     const fs = next; // TODO
//                     const vnode = if (flags & std.os.O.DIRECTORY != 0 or iter.rest().len > 0)
//                         try fs.createDir(component)
//                     else
//                         try fs.createFile(component);
//                     try next.insert(vnode);
//                     break :blk vnode;
//                 },
//                 else => |e| return e,
//             };
//         }

//         if (flags & std.os.O.NOFOLLOW == 0 and next_vnode.kind == .symlink) {
//             const old_vnode = next_vnode;
//             const target = next_vnode.symlink_target.?;
//             // TODO: check if isAbsolute?
//             next_vnode = try resolve(if (isAbsolute(target)) null else next_vnode.parent, target, 0);
//             if (next_vnode == old_vnode) return error.SymLinkLoop;
//         }

//         next = next_vnode;
//     }

//     return next;
// }
