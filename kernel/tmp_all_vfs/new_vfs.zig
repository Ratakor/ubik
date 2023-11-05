const std = @import("std");
const os = std.os;
const root = @import("root");
const time = @import("time.zig");
const SpinLock = root.SpinLock;
const Tree = root.Tree;
const DirectoryEntry = root.os.system.DirectoryEntry;
const log = std.log.scoped(.vfs);

// TODO: not sure about these errors
const AllocatorError = std.mem.Allocator.Error;
pub const OpenError = os.OpenError || AllocatorError;
pub const ReadError = os.ReadError || AllocatorError;
pub const ReadDirError = ReadError || error{IsNotDir};
pub const ReadLinkError = ReadError || error{IsNotLink};
pub const WriteError = os.WriteError || AllocatorError;
pub const CreateError = os.MakeDirError || AllocatorError;
pub const IoctlError = AllocatorError || os.UnexpectedError; // TODO
pub const StatError = os.FStatAtError || AllocatorError;

// TODO: Node as function with device as T?
pub const Node = struct {
    vtable: *const VTable = &.{},
    name: []const u8,
    kind: Kind,
    device: ?*anyopaque = null, // TODO: context, in stat?
    stat: std.os.Stat = .{
        .dev = undefined,
        .ino = undefined,
        .rdev = undefined,
        .blksize = undefined,
    },
    filesystem: u64 = 0, // TODO: ptr
    open_flags: u64 = 0, // TODO: read/write/append, ...

    ptr: ?*Node = null, // TODO: symlinks
    refcount: isize = 0, //std.atomic.Atomic(isize), // TODO

    // TODO: fill all entry with stub func instead of null?
    pub const VTable = struct {
        open: ?*const fn (self: *Node, flags: u64) OpenError!void = null,
        close: ?*const fn (self: *Node) void = null,
        read: ?*const fn (self: *Node, buf: []u8, offset: os.off_t) ReadError!usize = null,
        write: ?*const fn (self: *Node, buf: []const u8, offset: os.off_t) WriteError!usize = null,
        readDir: ?*const fn (self: *Node, index: usize) ReadDirError!*DirectoryEntry = null,
        findDir: ?*const fn (self: *Node, name: []const u8) error{}!*Node = null,
        // TODO: merge createFile and makeDir?
        createFile: ?*const fn (self: *Node, name: []const u8, mode: os.mode_t) CreateError!void = null,
        makeDir: ?*const fn (self: *Node, name: []const u8, mode: os.mode_t) CreateError!void = null,
        ioctl: ?*const fn (self: *Node, request: u64, arg: *anyopaque) IoctlError!u64 = null, // return u64?
        chmod: ?*const fn (self: *Node, mode: os.mode_t) error{}!void = null,
        chown: ?*const fn (self: *Node, uid: os.uid_t, gid: os.gid_t) error{}!void = null,
        truncate: ?*const fn (self: *Node) error{}!void = null,
        unlink: ?*const fn (self: *Node, name: []const u8) error{}!void = null,
        // TODO: not self but parent
        symLink: ?*const fn (self: *Node, name: []const u8, target: []const u8) CreateError!void = null,
        readLink: ?*const fn (self: *Node, buf: []u8) ReadLinkError!usize = null,
        stat: ?*const fn (self: *Node, buf: *os.Stat) StatError!void = null,

        // // TODO: this or set all field to @ptrCast(&stubFn)?
        // pub const default = blk: {
        //     var stub: VTable = undefined;
        //     for (std.meta.fields(VTable)) |field| {
        //         @field(stub, field.name) = @ptrCast(&stubFn);
        //     }
        //     break :blk stub;
        // };

        // fn stubFn() !void {
        //     // sched.setErrno(.NOSYS);
        //     return error.Unexpected;
        // }
    };

    /// https://en.wikipedia.org/wiki/Unix_file_types
    pub const Kind = enum {
        block_device,
        character_device,
        directory,
        named_pipe,
        sym_link,
        file,
        unix_domain_socket,
        whiteout,
        door,
        event_port,
        unknown,
    };

    var refcount_lock: SpinLock = .{};

    // TODO: use a spin lock instead lol
    pub fn lock(self: *Node) void {
        refcount_lock.lock();
        self.refcount = -1;
        refcount_lock.unlock();
    }

    pub fn open(self: *Node, flags: usize) OpenError!*Node {
        if (self.refcount >= 0) {
            refcount_lock.lock();
            self.refcount += 1;
            refcount_lock.unlock();
        }

        if (self.vtable.open) |func| {
            return func(self, flags);
        }
    }

    pub fn close(self: *Node) void {
        if (self.refcount == -1) return;

        refcount_lock.lock();
        defer refcount_lock.unlock();

        self.refcount -= 1;
        if (self.refcount == 0) {
            if (self.vtable.close) |func| {
                func(self);
            }

            // TODO: Node.deinit(); ?
        }
    }

    pub fn read(self: *Node, buf: []u8, offset: os.off_t) ReadError!usize {
        if (self.vtable.read) |func| {
            return func(self, buf, offset);
        } else {
            return error.Unexpected; // TODO
        }
    }

    pub fn write(self: *Node, buf: []const u8, offset: os.off_t) WriteError!usize {
        if (self.vtable.write) |func| {
            return func(self, buf, offset);
        } else {
            return error.NotOpenForWriting;
        }
    }

    pub fn readDir(self: *Node, index: usize) ReadDirError!*DirectoryEntry {
        if (self.kind != .directory) return error.IsNotDir;

        if (self.vtable.readDir) |func| {
            return func(self, index);
        } else {
            return error.Unexpected; // TODO
        }
    }

    pub fn findDir(self: *Node, name: []const u8) !*Node {
        if (self.kind != .directory) return error.IsNotDir;

        if (self.vtable.findDir) |func| {
            return func(self, name);
        } else {
            return error.Unexpected; // TODO
        }
    }

    pub fn ioctl(self: *Node, request: u64, arg: *anyopaque) IoctlError!u64 {
        if (self.vtable.ioctl) |func| {
            return func(self, request, arg);
        } else {
            return error.Unexpected; // TODO
        }
    }

    pub fn chmod(self: *Node, mode: os.mode_t) !void {
        if (self.vtable.chmod) |func| {
            return func(self, mode);
        }
    }

    pub fn chown(self: *Node, uid: os.uid_t, gid: os.gid_t) !void {
        if (self.vtable.chown) |func| {
            return func(self, uid, gid);
        }
    }

    pub fn truncate(self: *Node) error{}!void {
        if (self.vtable.truncate) |func| {
            return func(self);
        } else {
            return error.Unexpected; // TODO
        }
    }

    pub fn readlink(self: *Node, buf: []u8) error{}!void {
        if (self.vtable.readLink) |func| {
            return func(self, buf);
        } else {
            return error.Unexpected; // TODO
        }
    }
};

pub const Entry = struct {
    name: []u8, // TODO: const?
    file: ?*Node = null,
    device: ?[]u8 = null, // TODO
    fs_type: ?[]u8 = null, // TODO
};

pub const FileDescriptor = struct {
    node: *Node,
    offset: os.off_t,
    mode: os.mode_t,
};

pub const MountFn = *const fn (arg: []const u8, mount_point: []const u8) *Node;

var filesystems: std.StringHashMapUnmanaged(MountFn) = .{};
var tree = Tree(*Entry).init(root.allocator);
var vfs_lock: SpinLock = .{};

pub fn init() void {
    const root_node = root.allocator.create(Entry) catch unreachable;
    root_node.* = .{ .name = root.allocator.dupe(u8, "root") catch unreachable };
    tree.setRoot(root_node) catch unreachable;
}

pub fn registerFileSystem(name: []const u8, mountFn: MountFn) !void {
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

pub fn symLink(name: []const u8, target: []const u8) !void {
    _ = target;
    _ = name;
    // TODO
}

pub fn unlink(name: []const u8) !void {
    _ = name;
    // TODO
}

pub fn mount(path: []const u8, file: *Node) !*Node {
    std.debug.assert(std.fs.path.isAbsolute(path));

    vfs_lock.lock();
    defer vfs_lock.unlock();

    file.refcount = -1;

    var node = tree.root.?;
    var iter = std.mem.tokenizeScalar(u8, path, std.fs.path.sep);

    // TODO: this is makePath, extract it?
    while (iter.next()) |component| {
        for (node.children.items) |child| {
            const entry = child.value;
            if (std.mem.eql(u8, entry.name, component)) {
                node = child;
                break;
            }
        } else {
            // component not found in node.children so we create it
            const entry = try root.allocator.create(Entry);
            entry.* = .{ .name = try root.allocator.dupe(u8, component) };
            node = try tree.insert(node, entry);
        }
    }

    const entry = node.value;

    if (entry.file) |_| {
        log.warn("path {s} is already mounted!", .{path});
        // TODO: return or throw err?
    }
    entry.file = file;

    log.info("mounted `{s}` to `{s}`", .{ file.name, path });

    return node;
}

// TODO
fn readDirMapper(self: *Node, index: usize) ReadDirError!*DirectoryEntry {
    if (self.device) |device| {
        const dev: *Tree(*Entry).Node = @ptrCast(device);

        if (index == 0) {
            const dirent = try root.allocator.create(DirectoryEntry);
            @memcpy(dirent.name[0..], ".");
            dirent.ino = 0;
            return dirent;
        } else if (index == 1) {
            const dirent = try root.allocator.create(DirectoryEntry);
            @memcpy(dirent.name[0..], "..");
            dirent.ino = 1;
            return dirent;
        }

        index -= 2;
        var i: usize = 0;
        for (dev.children.items) |child| {
            if (i == index) {
                const entry = child.value;
                const dirent = try root.allocator.create(DirectoryEntry);
                @memcpy(dirent, entry.name); // TODO
                dirent.ino = i;
                return dirent;
            }
            i += 1;
        }
    }

    return null;
}

// TODO
fn mapper() !*Node {
    const node = try root.allocator.create(Node);
    node.* = .{
        .vtable = .{ .readDir = readDirMapper },
        .mode = 0o555,
        .kind = .directory,
        .ctime = time.now(),
        .mtime = time.now(),
        .atime = time.now(),
    };
    return node;
}
