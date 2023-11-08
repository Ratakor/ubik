const std = @import("std");
const root = @import("root");
const vfs = root.vfs;
const vmm = root.vmm;
const pmm = root.pmm;

// TODO

const file_vtable: vfs.Node.VTable = .{
    .read = File.read,
    .write = File.write,
    .stat = File.stat,
};

const dir_vtable: vfs.Node.VTable = .{
    .open = Dir.open,
    .readDir = Dir.read,
    .insert = Dir.insert,
    .stat = Dir.stat,
};

const fs_vtable: vfs.FileSystem.VTable = .{
    .createFile = FileSystem.createFile,
    .createDir = FileSystem.createDir,
    .createSymlink = FileSystem.createSymlink,
    .allocInode = FileSystem.allocInode,
};

const vtable: vfs.Node.VTable = .{
    .read = File.read,
    .write = File.write,
    .stat = File.stat,
    .truncate = File.truncate,
};

const File = struct {
    node: vfs.Node,
    data: std.ArrayListAlignedUnmanaged(u8, blksize) = .{},

    const blksize = std.mem.page_size;

    fn read(node: *vfs.Node, buf: []u8, offset: std.os.off_t) vfs.ReadError!usize {
        const self = @fieldParentPtr(File, "node", node);
        if (offset >= self.data.items.len) {
            return 0;
        }
        const bytes_read = @min(buf.len, self.data.items.len - offset);
        const u_offset: usize = @intCast(offset);
        @memcpy(buf[0..bytes_read], self.data.items[u_offset .. u_offset + bytes_read]);
        return bytes_read;
    }

    fn write(node: *vfs.Node, buf: []const u8, offset: std.os.off_t) vfs.WriteError!usize {
        const self = @fieldParentPtr(File, "node", node);
        try self.data.insertSlice(root.allocator, @intCast(offset), buf);
        return buf.len;
    }

    fn stat(node: *vfs.Node, statbuf: *std.os.Stat) vfs.StatError!void {
        const self = @fieldParentPtr(File, "node", node);
        statbuf.* = .{
            .dev = undefined,
            .ino = node.inode,
            .mode = node.mode, // TODO: 0o777 | std.os.S.IFREG,
            .nlink = node.nlink,
            .uid = node.uid,
            .gid = node.gid,
            .rdev = undefined,
            .size = @intCast(self.data.items.len),
            .blksize = blksize,
            .blocks = std.math.divCeil(usize, self.data.items.len, 512), // TODO: use @divCeil
            .atim = node.atim,
            .mtim = node.mtim,
            .ctim = node.ctim,
        };
    }

    // TODO
    fn mmap(node: *vfs.Node, file_page: usize, flags: u64) !*anyopaque {
        const self = @fieldParentPtr(File, "node", node);
        return if (flags & std.os.MAP.SHARED != 0)
            @intFromPtr(self.data[file_page * blksize ..].ptr) - vmm.hhdm_offset
        else blk: {
            const data = try root.allocator.alloc(u8, blksize);
            @memcpy(data, self.data[file_page * blksize ..][0..blksize]);
            break :blk @intFromPtr(data.ptr) - vmm.hhdm_offset;
        };
    }

    fn truncate(node: *vfs.Node, length: usize) vfs.DefaultError!void {
        const self = @fieldParentPtr(File, "node", node);
        try self.data.resize(root.allocator, length);
    }

    fn create(parent: *vfs.Node, name: []const u8, mode: std.os.mode_t) vfs.CreateError!void {
        _ = mode;
        _ = name;
        _ = parent;
        const node = try root.allocator.create(vfs.Node);
        node.* = .{
            .vtable = &vtable,
        };
        return node;
        // TODO
    }

    // TODO: create_resource
    // TODO: instantiate?
    // TODO: mount
    // TODO: create
    // TODO: symlink
    // TODO: link
};

// pub const MountFn = *const fn (arg: []const u8, mount_point: []const u8) *Node;
fn mount(parent: *vfs.Node, name: []const u8, _: *vfs.Node) *vfs.Node {
    _ = name;
    _ = parent;
    // return parent.createFile(parent,
    // TODO

}

const Dir = struct {
    node: vfs.Node,
    children: std.ArrayListUnmanaged(*vfs.Node) = .{},

    fn open(node: *vfs.Node, name: []const u8, flags: u64) vfs.OpenError!*vfs.Node {
        _ = flags;

        const self = @fieldParentPtr(Dir, "node", node);
        for (self.children.items) |child| {
            if (std.mem.eql(u8, child.name, name)) {
                return child;
            }
        }

        return vfs.OpenError.FileNotFound;
    }

    // TODO
    fn read(node: *vfs.Node, buf: []u8, offset: *usize) vfs.ReadDirError!usize {
        const self = @fieldParentPtr(Dir, "node", node);

        var dir_ent: *std.os.system.DirectoryEntry = @ptrCast(@alignCast(buf.ptr));
        var buf_offset: usize = 0;

        while (offset.* < self.children.items.len) : (offset.* += 1) {
            const child = self.children.items[offset.*];
            const real_size = child.name.len + 1 - (1024 - @sizeOf(std.os.system.DirectoryEntry));

            if (buf_offset + real_size > buf.len) break;

            dir_ent.d_off = 0;
            dir_ent.d_ino = node.inode;
            dir_ent.d_reclen = @truncate(real_size);
            dir_ent.d_type = return @intFromEnum(child.kind);
            @memcpy(dir_ent.d_name[0..child.name.len], child.name); // TODO
            dir_ent.d_name[child.name.len] = 0;
            buf_offset += real_size;
            dir_ent = @ptrCast(@alignCast(buf[buf_offset..]));
        }

        return buf_offset;
    }

    fn insert(node: *vfs.Node, new_child: *vfs.Node) vfs.InsertError!void {
        const self = @fieldParentPtr(Dir, "node", node);
        for (self.children.items) |child| {
            if (std.mem.eql(u8, child.name, new_child.name)) {
                return error.PathAlreadyExists;
            }
        }
        try self.children.append(root.allocator, new_child);
    }

    fn stat(node: *vfs.Node, buf: *std.os.Stat) vfs.StatError!void {
        buf.* = std.mem.zeroes(std.os.Stat);
        buf.ino = node.inode;
        buf.mode = 0o777 | std.os.S.IFDIR; // TODO
    }
};

const FileSystem = struct {
    filesystem: vfs.FileSystem,
    root: Dir,
    inode_counter: u64,

    fn createFile(fs: *vfs.FileSystem) !*vfs.Node {
        const file = try root.allocator.create(File);

        // TODO!: are data field, parent or kind field correctly put in file?
        file.* = .{
            .node = .{
                .vtable = &file_vtable,
                .filesystem = fs,
                .kind = .file,
                .name = "", // TODO
                .inode = allocInode(fs),
            },
        };

        return &file.node;
    }

    fn createDir(fs: *vfs.FileSystem) !*vfs.Node {
        const dir = try root.allocator.create(Dir);

        dir.* = .{
            .node = .{
                .vtable = &dir_vtable,
                .filesystem = fs,
                .kind = .directory,
                .name = "", // TODO
                .inode = allocInode(fs),
            },
        };

        return &dir.node;
    }

    fn createSymlink(fs: *vfs.FileSystem, target: []const u8) !*vfs.Node {
        const symlink = try root.allocator.create(vfs.Node);
        errdefer root.allocator.destroy(symlink);

        symlink.* = .{
            // .vtable = &?,
            .filesystem = fs,
            .kind = .symlink,
            .symlink_target = try root.allocator.dupe(u8, target),
            .name = "", // TODO
            .inode = allocInode(fs),
        };

        return symlink;
    }

    // TODO: check if max + does this really need to be outside of vfs.zig?
    fn allocInode(fs: *vfs.FileSystem) u64 {
        const self = @fieldParentPtr(FileSystem, "filesystem", fs);
        return @atomicRmw(u64, &self.inode_counter, .Add, 1, .Release);
    }
};

pub fn init(name: []const u8, parent: ?*vfs.Node) !*vfs.Node {
    const fs = try root.allocator.create(FileSystem);

    fs.* = .{
        .filesystem = .{
            .vtable = &fs_vtable,
        },
        .root = .{
            .node = .{
                .vtable = &dir_vtable,
                .filesystem = &fs.filesystem,
                .kind = .directory,
                .name = name,
                .parent = parent,
                .inode = 0,
            },
        },
        .inode_counter = 1,
    };

    return &fs.root.node;
}
