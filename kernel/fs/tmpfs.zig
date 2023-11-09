const std = @import("std");
const root = @import("root");
const vfs = root.vfs;
const sched = root.sched;
const time = root.time;
const SpinLock = root.SpinLock;
const assert = std.debug.assert;

// TODO: atim, mtim, ctim modification + lock (in vfs?)
// TODO: replace error.Unexpected and remove some errors that get sanitized
// TODO: add inode_counter -> st_dev, st_ino
// TODO: add errdefers

// const Inode = struct {
//     u: union {
//         target: []u8, // symlink
//         content: std.ArrayListAlignedUnmanaged(u8, blksize), // file
//         children: std.StringHashMapUnmanaged(*vfs.Node), // directory
//     },
//     inode_counter: *std.os.ino_t,
const Inode = union {
    target: []u8, // symlink
    data: std.ArrayListAlignedUnmanaged(u8, blksize), // file
    children: std.StringHashMapUnmanaged(*vfs.Node), // directory

    const blksize = std.mem.page_size;
    // different vtable for each kind?
    const vtable = vfs.Node.VTable{
        .open = open,
        .close = close,
        .read = read,
        .readlink = readlink,
        // TODO: readdir
        .write = write,
        .chmod = chmod,
        .chown = chown,
        .truncate = truncate,
        .unlink = unlink,
        .stat = stat,
        .create = create,
        .mkdir = create,
        .symlink = symlink,
        .link = link,
    };

    fn init(kind: vfs.Node.Kind, target: ?[]const u8) !*Inode {
        const inode = try root.allocator.create(Inode);
        errdefer root.allocator.destroy(inode);

        switch (kind) {
            .symlink => inode.target = try root.allocator.dupe(u8, target.?),
            .directory => inode.children = .{},
            .file => inode.data = .{},
            else => unreachable,
        }

        return inode;
    }

    // TODO
    fn deinit(node: *vfs.Node) void {
        const self: *Inode = @ptrCast(@alignCast(node.context));
        switch (node.kind) {
            .directory => {}, // TODO
            .file => self.data.deinit(),
            .symlink => root.allocator.free(self.target),
            else => unreachable,
        }
        // ...
        @compileError("not finished");
    }
};

fn open(node: *vfs.Node, flags: u64) vfs.OpenError!void {
    _ = flags;
    node.stat.atim = time.realtime;
}

fn close(node: *vfs.Node) void {
    _ = node;
}

fn read(node: *vfs.Node, buf: []u8, offset: std.os.off_t) vfs.ReadError!usize {
    if (node.kind != .file) return error.Unexpected;

    node.lock.lock();
    defer node.lock.unlock();

    node.stat.atim = time.realtime;

    const self: *Inode = @ptrCast(@alignCast(node.context));
    if (offset >= self.data.items.len) {
        return 0;
    }

    // TODO
    const u_offset: usize = @intCast(offset);
    const bytes_read = @min(buf.len, self.data.items.len - u_offset);
    @memcpy(buf[0..bytes_read], self.data.items[u_offset .. u_offset + bytes_read]);

    return bytes_read;
}

fn readlink(node: *vfs.Node, buf: []u8) vfs.ReadLinkError!usize {
    assert(node.kind == .symlink);

    node.lock.lock();
    defer node.lock.unlock();

    const self: *Inode = @ptrCast(@alignCast(node.context));
    const bytes_read = @min(buf.len, self.target.len);
    @memcpy(buf[0..bytes_read], self.target[0..bytes_read]);
    return bytes_read;
}

// TODO
// readdir: *const fn (node: *Node, index: usize) ReadDirError!*DirectoryEntry
// fn readdir(node: *vfs.Node, buf: []u8, offset: *usize) vfs.ReadDirError!usize {
//     const self = @fieldParentPtr(Dir, "node", node);

//     var dirent: *std.os.system.DirectoryEntry = @ptrCast(@alignCast(buf.ptr));
//     var buf_offset: usize = 0;

//     while (offset.* < self.children.items.len) : (offset.* += 1) {
//         const child = self.children.items[offset.*];
//         const real_size = child.name.len + 1 - (1024 - @sizeOf(std.os.system.DirectoryEntry));

//         if (buf_offset + real_size > buf.len) break;

//         dirent.d_off = 0;
//         dirent.d_ino = node.inode;
//         dirent.d_reclen = @truncate(real_size);
//         dirent.d_type = return @intFromEnum(child.kind);
//         @memcpy(dirent.d_name[0..child.name.len], child.name); // TODO
//         dirent.d_name[child.name.len] = 0;
//         buf_offset += real_size;
//         dirent = @ptrCast(@alignCast(buf[buf_offset..]));
//     }

//     return buf_offset;
// }

fn write(node: *vfs.Node, buf: []const u8, offset: std.os.off_t) vfs.WriteError!usize {
    if (node.kind != .file) return error.Unexpected;

    node.lock.lock();
    defer node.lock.unlock();

    node.stat.atim = time.realtime;
    node.stat.mtim = time.realtime;

    const self: *Inode = @ptrCast(@alignCast(node.context));
    try self.data.insertSlice(root.allocator, @intCast(offset), buf); // TODO: incorrect

    return buf.len;
}

fn chmod(node: *vfs.Node, mode: std.os.mode_t) vfs.DefaultError!void {
    node.lock.lock();
    defer node.lock.unlock();

    // mtim atim
    node.stat.mode &= ~@as(std.os.mode_t, 0o777);
    node.stat.mode |= mode & 0o777;
}

fn chown(node: *vfs.Node, uid: std.os.uid_t, gid: std.os.gid_t) vfs.DefaultError!void {
    node.lock.lock();
    defer node.lock.unlock();

    // mtim atim
    node.stat.uid = uid;
    node.stat.gid = gid;
}

fn truncate(node: *vfs.Node, length: usize) vfs.DefaultError!void {
    if (node.kind != .file) return error.Unexpected;

    node.lock.lock();
    defer node.lock.unlock();

    const self: *Inode = @ptrCast(@alignCast(node.context));

    // mtim = atim?
    // atim

    try self.data.resize(root.allocator, length);
    // TODO bzero memory if length > self.data.len
}

// TODO: man 2 unlink
fn unlink(parent: *vfs.Node, name: []const u8) vfs.UnlinkError!void {
    if (parent.kind != .directory) return error.Unexpected;

    parent.lock.lock();
    defer parent.lock.unlock();

    const self: *Inode = @ptrCast(@alignCast(parent.context));

    const kv = self.children.fetchRemove(name) orelse return error.FileNotFound;
    const child = kv.value;
    // check if no process have the file open too
    switch (child.kind) {
        .directory => {
            return error.IsDir; // no
        },
        .file => {
            child.stat.nlink -= 1;
            if (child.stat.nlink == 0) {
                // deinit child.context
            }
            // child.deinit();
        },
        .symlink => {
            // child.deinit Context
            // child.deinit
        },
        else => unreachable,
    }
}

fn stat(node: *vfs.Node, statbuf: *std.os.Stat) vfs.StatError!void {
    node.lock.lock();
    defer node.lock.unlock();

    const self: *Inode = @ptrCast(@alignCast(node.context));
    switch (node.kind) {
        .directory => {
            // TODO: set in create, unlink, etc
            // node.stat.nlink =
        },
        .symlink => {
            node.stat.size = @intCast(self.target.len);
        },
        .file => {
            node.stat.size = @intCast(self.data.items.len);
            node.stat.blocks = @intCast(std.math.divCeil(usize, self.data.items.len, 512) catch unreachable); // TODO: use @divCeil
        },
        else => unreachable,
    }

    statbuf.* = node.stat;
}

fn create(parent: *vfs.Node, name: []const u8, mode: std.os.mode_t) vfs.CreateError!void {
    assert(parent.kind == .directory);

    parent.lock.lock();
    defer parent.lock.unlock();

    // TODO
    // const self: *Inode = @ptrCast(@alignCast(parent.context));
    // const gop = try self.children.getOrPut(root.allocator, name);
    // if (gop.found_existing) {
    //     return error.PathAlreadyExists;
    // }

    const node = try vfs.Node.init(&Inode.vtable, name, parent, mode);
    const inode = try Inode.init(node.kind, null);
    // node.stat.dev = parent.stat.dev; // parent holds dev_id (it goes back up to the mounted node)
    // node.stat.ino = @atomicRmw(os.ino_t, self.inode_counter, .Add, 1, .Release);
    node.stat.uid = sched.currentProcess().user;
    node.stat.gid = sched.currentProcess().group;
    node.stat.blksize = Inode.blksize;
    node.context = @ptrCast(inode);
    // gop.value_ptr.* = node;
}

fn symlink(parent: *vfs.Node, name: []const u8, target: []const u8) vfs.CreateError!void {
    assert(parent.kind == .directory);

    parent.lock.lock();
    defer parent.lock.unlock();

    // TODO
    // const self: *Inode = @ptrCast(@alignCast(parent.context));
    // const gop = try self.children.getOrPut(root.allocator, name);
    // if (gop.found_existing) {
    //     return error.PathAlreadyExists;
    // }

    const node = try vfs.Node.init(&Inode.vtable, name, parent, 0o777 | std.os.S.IFLNK);
    const inode = try Inode.init(node.kind, target);
    // node.stat.dev = parent.stat.dev;
    // node.stat.ino = @atomicRmw(os.ino_t, self.inode_counter, .Add, 1, .Release);
    node.stat.uid = sched.currentProcess().user;
    node.stat.gid = sched.currentProcess().group;
    node.stat.blksize = Inode.blksize;
    node.context = @ptrCast(inode);
    // gop.value_ptr.* = node;
}

fn link(parent: *vfs.Node, name: []const u8, node: *vfs.Node) vfs.CreateError!void {
    assert(parent.kind == .directory);

    if (node.kind == .directory) {
        return error.IsDir;
    }

    parent.lock.lock();
    defer parent.lock.unlock();

    const self: *Inode = @ptrCast(@alignCast(parent.context));
    const gop = try self.children.getOrPut(root.allocator, name);
    if (gop.found_existing) {
        return error.PathAlreadyExists;
    }

    node.stat.nlink += 1;
    gop.value_ptr.* = node;
}

// TODO
// fn mmap(node: *vfs.Node, file_page: usize, flags: u64) !*anyopaque {
//     const self = @fieldParentPtr(Inode, "vnode", node);
//     return if (flags & std.os.MAP.SHARED != 0)
//         @intFromPtr(self.data[file_page * blksize ..].ptr) - vmm.hhdm_offset
//     else blk: {
//         const data = try root.allocator.alloc(u8, blksize);
//         @memcpy(data, self.data[file_page * blksize ..][0..blksize]);
//         break :blk @intFromPtr(data.ptr) - vmm.hhdm_offset;
//     };
// }

// TODO
fn mount(parent: *vfs.Node, name: []const u8, _: *vfs.Node) vfs.CreateError!*vfs.Node {
    // const fs = try instantiate();
    // return fs.create(parent, name, 0o777 | std.os.S.IFDIR);

    // parent.create_no_inode() -> *vfs.Node;

    // TODO the problem is that this won't work if parent is not of the same filesystem
    // and it returns nothing
    // _ = try create(parent, name, 0o777 | std.os.S.IFDIR);

    // TODO: use create
    const node = try vfs.Node.init(&Inode.vtable, name, parent, 0o777 | std.os.S.IFDIR);
    const inode = try Inode.init(node.kind, null);
    node.stat.dev = vfs.allocDevID();
    node.stat.ino = 0;
    // node.stat.ino = @atomicRmw(os.ino_t, self.inode_counter, .Add, 1, .Release);
    node.stat.uid = 0;
    node.stat.gid = 0;
    node.stat.blksize = Inode.blksize;
    node.context = @ptrCast(inode);

    return node;
}

pub fn init() void {
    vfs.registerFileSystem("tmpfs", mount) catch unreachable;
}
