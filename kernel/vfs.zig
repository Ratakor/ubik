const std = @import("std");
const os = std.os;
const root = @import("root");
const time = root.time;
const SpinLock = root.SpinLock;
const log = std.log.scoped(.vfs);

pub const DirectoryEntry = @import("ubik").dirent; // TODO

// TODO
pub const DefaultError = error{
    OperationNotSupported,
    FileNotFound,
} || std.mem.Allocator.Error || os.UnexpectedError;
pub const OpenError = os.OpenError || DefaultError;
pub const ReadError = os.ReadError || DefaultError;
pub const ReadDirError = ReadError || error{IsNotDir};
pub const ReadLinkError = ReadError || error{IsNotLink};
pub const WriteError = os.WriteError || DefaultError;
pub const CreateError = os.MakeDirError || DefaultError || error{IsDir};
pub const StatError = os.FStatError || DefaultError;
pub const UnlinkError = DefaultError || error{IsDir};

// TODO: rename VNode
// TODO: remove undefined/null initializer if the field are used to ensure it's initialized correcly
pub const Node = struct {
    name: []u8,
    context: *anyopaque,
    vtable: *const VTable,

    // filesystem: *FileSystem, // TODO
    kind: Kind, // TODO: useless since S.IF exist?
    stat: os.Stat, // TODO mode = 0o666 | S.IFREG by default
    open_flags: u64 = undefined, // TODO: read/write/append, ...

    // TODO
    mount_point: ?*Node = null,
    mounted_node: ?*Node = null,

    refcount: usize, // TODO
    lock: SpinLock = .{}, // TODO: use a u64 with flags and lock with atomic OR
    // status: i32, // TODO
    // event: Event = .{}, // TODO
    parent: *Node, // undefined for root // TODO
    // redirection: ?*Node, // TODO: only for .. and . ?

    // defined in filesystems implementations
    // children: std.StringHashMapUnmanaged(*Node) = .{},
    // symlink_target: ?[]u8 = null,

    pub const VTable = struct {
        // read_vnode
        // write_vnode
        // remove_vnode
        // secure_vnode
        // resolve
        // access (man 2 access)

        create: *const fn (parent: *Node, name: []const u8, mode: os.mode_t) CreateError!void = @ptrCast(&stubFn),
        mkdir: *const fn (parent: *Node, name: []const u8, mode: os.mode_t) CreateError!void = @ptrCast(&stubFn),
        symlink: *const fn (parent: *Node, name: []const u8, target: []const u8) CreateError!void = @ptrCast(&stubFn),
        link: *const fn (parent: *Node, name: []const u8, node: *Node) CreateError!void = @ptrCast(&stubFn),
        // rename: *const fn (parent: *Node, name: []const u8, node: *Node) DefaultError!void = @ptrCast(&stubFn),
        unlink: *const fn (parent: *Node, name: []const u8) UnlinkError!void = @ptrCast(&stubFn),
        // rmdir: *const fn (parent: *Node, name: []const u8) DefaultError!void = @ptrCast(&stubFn),
        readlink: *const fn (node: *Node, buf: []u8) ReadLinkError!usize = @ptrCast(&stubFn),

        // opendir
        // closedir
        // free_context_dir
        // rewinddir
        // TODO: use a stream for DIR
        // readdir: *const fn (node: *Node, index: usize) ReadDirError!*DirectoryEntry = @ptrCast(&stubFn),

        open: *const fn (node: *Node, flags: u64) OpenError!void = @ptrCast(&stubFn),
        close: *const fn (node: *Node) void = @ptrCast(&stubFn),
        // free_context
        read: *const fn (node: *Node, buf: []u8, offset: os.off_t) ReadError!usize = @ptrCast(&stubFn),
        write: *const fn (node: *Node, buf: []const u8, offset: os.off_t) WriteError!usize = @ptrCast(&stubFn),
        ioctl: *const fn (node: *Node, request: u64, arg: *anyopaque) DefaultError!u64 = @ptrCast(&stubFn),
        // setflags
        // rstat
        // wstat
        // fsync

        // init
        // mount
        // unmount
        // sync

        // rfsstat
        // wfsstat

        // open_indexdir
        // close_indexdir
        // free_context_indexdir
        // rewind_indexdir
        // read_indexdir

        // create_index
        // remove_index
        // rename_index
        // stat_index

        // open_attrdir
        // close_attrdir
        // free_context_attrdir
        // rewind_attrdir
        // read_attrdir

        // write_attr
        // read_attr
        // remove_attr
        // rename_attr
        // stat_attr

        // open_query
        // close_query
        // free_context
        // read_query

        chmod: *const fn (node: *Node, mode: os.mode_t) DefaultError!void = @ptrCast(&stubFn),
        chown: *const fn (node: *Node, uid: os.uid_t, gid: os.gid_t) DefaultError!void = @ptrCast(&stubFn),
        truncate: *const fn (node: *Node, length: usize) DefaultError!void = @ptrCast(&stubFn),
        stat: *const fn (node: *Node, statbuf: *os.Stat) StatError!void = @ptrCast(&stubFn),

        fn stubFn() !void {
            return error.OperationNotSupported;
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

        pub inline fn fromMode(mode: os.mode_t) Kind {
            return switch (mode & os.S.IFMT) {
                os.S.IFDIR => .directory,
                os.S.IFCHR => .character_device,
                os.S.IFBLK => .block_device,
                os.S.IFREG => .file,
                os.S.IFIFO => .named_pipe,
                os.S.IFLNK => .symlink,
                os.S.IFSOCK => .unix_domain_socket,
                else => .unknown,
            };
        }
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

    pub fn init(
        vtable: *const VTable,
        name: []const u8,
        parent: *Node,
        mode: os.mode_t,
    ) !*Node {
        const node = try root.allocator.create(Node);
        errdefer root.allocator.destroy(node);

        node.* = .{
            .vtable = vtable, // TODO
            .context = undefined, // TODO
            .name = try root.allocator.dupe(u8, name),
            .kind = Kind.fromMode(mode),
            .stat = .{
                .dev = 0, // undefined,
                .ino = 0, // undefined,
                .mode = mode,
                .nlink = 1,
                .uid = 0,
                .gid = 0,
                .rdev = 0, // undefined,
                .size = 0,
                .blksize = 0, // undefined,
                .blocks = 0,
                .atim = time.realtime,
                .mtim = time.realtime,
                .ctim = time.realtime,
                .birthtim = time.realtime,
            },
            .refcount = 0,
            .parent = parent,
        };

        return node;
    }

    // TODO
    pub inline fn can_mmap(self: *Node) bool {
        return std.os.S.ISREG(self.stat.mode);
    }

    pub fn getEffectiveNode(self: *Node, follow_symlinks: bool) *Node {
        // if (self.redirection) |redirection| {
        //     return getEffectiveNode(redirection, follow_symlinks);
        // }
        if (self.mounted_node) |mounted_node| {
            return getEffectiveNode(mounted_node, follow_symlinks);
        }
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

    // TODO: lock defer unlock by default for everything
    // TODO: modify atime too?
    // TODO: asserts
    // TODO: call getEffectiveNode and use it instead of self?

    pub inline fn readlink(self: *Node, buf: []u8) ReadLinkError!void {
        if (self.kind != .symlink) return error.IsNotLink;
        return self.vtable.readlink(self, buf);
    }

    pub inline fn readdir(self: *Node, index: usize) ReadDirError!*DirectoryEntry {
        if (self.kind != .directory) return error.IsNotDir;
        return self.vtable.readdir(self, index);
    }

    // TODO
    pub inline fn open(self: *Node, flags: u64) OpenError!*Node {
        self.refcount += 1;
        return self.vtable.open(self, flags);
    }

    // TODO
    pub inline fn close(self: *Node) void {
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

    pub inline fn stat(self: *Node, statbuf: *os.Stat) StatError!void {
        return self.vtable.stat(self, statbuf);
    }

    pub fn writePath(self: *Node, writer: anytype) !void {
        if (self.parent) |parent| {
            try parent.writePath(writer);
            try writer.writeAll(std.fs.path.sep_str);
        }
        try writer.writeAll(self.name);
    }
};

// TODO: unused
pub const FileSystem = struct {
    vtable: *const VTable,
    context: *anyopaque,

    pub const VTable = struct {
        create: *const fn (self: *FileSystem, parent: *Node, name: []const u8, mode: os.mode_t) CreateError!*Node,
        symlink: *const fn (self: *FileSystem, parent: *Node, name: []const u8, target: []const u8) CreateError!*Node,
        link: *const fn (self: *FileSystem, parent: *Node, name: []const u8, node: *Node) CreateError!*Node,
    };

    pub inline fn create(self: *FileSystem, parent: *Node, name: []const u8, mode: os.mode_t) CreateError!*Node {
        return self.vtable.create(self, parent, name, mode);
    }

    pub inline fn symlink(self: *FileSystem, parent: *Node, name: []const u8, target: []const u8) CreateError!*Node {
        return self.vtable.symlink(self, parent, name, target);
    }

    pub inline fn link(self: *FileSystem, parent: *Node, name: []const u8, node: *Node) CreateError!*Node {
        return self.vtable.create(self, parent, name, node);
    }
};

pub const FileDescriptor = struct {
    node: *Node,
    offset: os.off_t,
    // TODO: mode, lock, flags, refcount?
};

// pub const MountFn = *const fn (parent: *Node, name: []const u8, source: *Node) CreateError!*Node;

var filesystems: std.StringHashMapUnmanaged(MountFn) = .{};
pub var root_node: *Node = undefined;
var vfs_lock: SpinLock = .{};
var dev_id_counter: os.dev_t = 0;

pub fn init() void {
    root_node = Node.init(undefined, "", undefined, undefined) catch unreachable; // TODO
}

pub fn registerFileSystem(name: []const u8, mountFn: MountFn) !void {
    vfs_lock.lock();
    defer vfs_lock.unlock();

    const rv = try filesystems.getOrPut(root.allocator, name);
    std.debug.assert(rv.found_existing == false);
    rv.value_ptr.* = mountFn;
    log.info("registered filesystem `{s}`", .{name});
}

pub fn allocDevID() os.dev_t {
    return @atomicRmw(os.dev_t, &dev_id_counter, .Add, 1, .Monotonic);
}

/// parent: new node directory
/// source: new node original path e.g. /dev/sda1
/// target: path for the new node
/// fs_name: file system name
pub const MountFn = *const fn (parent: *Node, name: []const u8, source: *Node) CreateError!*Node;
pub fn mount(parent: *Node, source: ?[]const u8, target: []const u8, fs_name: []const u8) !void {
    _ = fs_name;
    _ = target;
    _ = source;
    _ = parent;
    vfs_lock.lock();
    defer vfs_lock.unlock();
    // TODO
}

// TODO

// pub fn create(parent: *Node, name: []const u8, mode: os.mode_t) !*Node {
//     _ = mode;
//     _ = name;
//     _ = parent;
//     // TODO
// }

// pub fn symlink(parent: *Node, name: []const u8, target: []const u8) !void {
//     _ = target;
//     _ = name;
//     _ = parent;
//     // TODO
// }

// pub fn unlink(parent: *Node, name: []const u8) !void {
//     _ = name;
//     _ = parent;
//     // TODO
// }

pub fn create(parent: *Node, name: []const u8, mode: os.mode_t) CreateError!void {
    return parent.vtable.create(parent, name, mode);
}

pub fn mkdir(parent: *Node, name: []const u8, mode: os.mode_t) CreateError!void {
    return parent.vtable.mkdir(parent, name, mode);
}

pub fn symlink(parent: *Node, name: []const u8, target: []const u8) CreateError!void {
    return parent.vtable.symlink(parent, name, target);
}

pub fn link(parent: *Node, name: []const u8, node: *Node) !CreateError!void {
    return parent.vtable.link(parent, name, node);
}

pub fn unlink(parent: *Node, name: []const u8) DefaultError!void {
    return parent.vtable.unlink(parent, name);
}

const Entry = struct {
    name: []u8,
    file: ?*Node = null, // inode
    // device: ?[]u8 = null,
    // fs_type: ?[]u8 = null,
};

// TODO: this uses Entry and Tree from previous commits
// pub const MountFn = *const fn (source: []const u8, target: []const u8) CreateError!*Node;
// pub fn mount(path: []const u8, local_root: *Node) !*Node {
//     if (!std.fs.path.isAbsolute(path)) return error.PathIsNotAbsolute;

//     vfs_lock.lock();
//     defer vfs_lock.unlock();

//     // TODO needed?
//     local_root.lock.lock();
//     defer local_root.lock.unlock();
//     // local_root.refcount = -1;

//     var node = root_node;
//     var iter = std.mem.tokenizeScalar(u8, path, std.fs.path.sep);
//     while (iter.next()) |component| {
//         const gop = try node.children.getOrPut(root.allocator, component);
//         if (gop.found_existing) {
//             node = gop.value_ptr.*;
//         } else {
//             const entry = try root.allocator.create(Entry);
//             entry.* = .{ .name = try root.allocator.dupe(u8, component) };
//             gop.value_ptr.* = entry;
//             // TODO
//             // node = tree.insert(node, entry);
//             // node = entry;
//         }
//     }

//     // const entry = node.value;
//     // if (entry.file) |_| {
//     //     return error.AlreadyMounted;
//     // }
//     // entry.file = local_root;

//     log.info("mounted `{s}` to `{s}`", .{ local_root.name, path });

//     return node;
// }

// TODO: yet another different implem of mount
// fn mount(source: *Node, target: *Node) void {
//     // lock?
//     std.debug.assert(target.mounted_node == null);
//     std.debug.assert(source.parent == undefined);

//     target.mounted_node = source;
//     source.parent = target.parent;
// }

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

// // TODO
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
