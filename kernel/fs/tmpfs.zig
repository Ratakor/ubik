const std = @import("std");
const root = @import("root");
const vfs = root.vfs;
const page_size = std.mem.page_size;

const file_vtable: vfs.VNode.VTable = .{
    .read = File.read,
    .write = File.write,
    .stat = File.stat,
};

const dir_vtable: vfs.VNode.VTable = .{
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

const File = struct {
    vnode: vfs.VNode,
    data: Data = Data.init(root.allocator),

    const Data = std.ArrayListAligned(u8, page_size);

    fn read(vnode: *vfs.VNode, buf: []u8, offset: usize, flags: usize) vfs.ReadError!usize {
        _ = flags;

        const self = @fieldParentPtr(File, "vnode", vnode);
        if (offset >= self.data.items.len) {
            return 0;
        }
        const bytes_read = @min(buf.len, self.data.items.len - offset);
        @memcpy(buf[0..bytes_read], self.data.items[offset .. offset + bytes_read]);
        return bytes_read;
    }

    fn write(vnode: *vfs.VNode, buf: []const u8, offset: usize, flags: usize) vfs.WriteError!usize {
        _ = flags;

        const self = @fieldParentPtr(File, "vnode", vnode);
        try self.data.insertSlice(offset, buf);
        return buf.len;
    }

    fn stat(vnode: *vfs.VNode, buf: *std.os.Stat) vfs.StatError!void {
        const self = @fieldParentPtr(File, "vnode", vnode);

        buf.* = std.mem.zeroes(std.os.Stat);
        buf.ino = vnode.inode;
        buf.mode = 0o777 | std.os.S.IFREG; // TODO
        buf.size = @intCast(self.data.items.len);
        buf.blksize = page_size;
        buf.blocks = @intCast(std.mem.alignForward(usize, self.data.items.len, page_size) / page_size);
    }
};

const Dir = struct {
    vnode: vfs.VNode,
    children: std.ArrayListUnmanaged(*vfs.VNode) = .{},

    fn open(vnode: *vfs.VNode, name: []const u8, flags: usize) vfs.OpenError!*vfs.VNode {
        _ = flags;

        const self = @fieldParentPtr(Dir, "vnode", vnode);
        for (self.children.items) |child| {
            if (std.mem.eql(u8, child.name, name)) {
                return child;
            }
        }

        return vfs.OpenError.FileNotFound;
    }

    // TODO
    fn read(vnode: *vfs.VNode, buf: []u8, offset: *usize) vfs.ReadDirError!usize {
        const self = @fieldParentPtr(Dir, "vnode", vnode);

        var dir_ent: *std.os.system.DirectoryEntry = @ptrCast(@alignCast(buf.ptr));
        var buf_offset: usize = 0;

        while (offset.* < self.children.items.len) : (offset.* += 1) {
            const child = self.children.items[offset.*];
            const real_size = child.name.len + 1 - (1024 - @sizeOf(std.os.system.DirectoryEntry));

            if (buf_offset + real_size > buf.len) break;

            dir_ent.d_off = 0;
            dir_ent.d_ino = vnode.inode;
            dir_ent.d_reclen = @truncate(real_size);
            dir_ent.d_type = return @intFromEnum(child.kind);
            @memcpy(dir_ent.d_name[0..child.name.len], child.name); // TODO
            dir_ent.d_name[child.name.len] = '\x00';
            buf_offset += real_size;
            dir_ent = @ptrCast(@alignCast(buf[buf_offset..]));
        }

        return buf_offset;
    }

    fn insert(vnode: *vfs.VNode, new_child: *vfs.VNode) vfs.InsertError!void {
        const self = @fieldParentPtr(Dir, "vnode", vnode);
        for (self.children.items) |child| {
            if (std.mem.eql(u8, child.name, new_child.name)) {
                return error.PathAlreadyExists;
            }
        }
        try self.children.append(root.allocator, new_child);
    }

    fn stat(vnode: *vfs.VNode, buf: *std.os.Stat) vfs.StatError!void {
        buf.* = std.mem.zeroes(std.os.Stat);
        buf.ino = vnode.inode;
        buf.mode = 0o777 | std.os.S.IFDIR; // TODO
    }
};

const FileSystem = struct {
    filesystem: vfs.FileSystem,
    root: Dir,
    inode_counter: u64,

    fn createFile(fs: *vfs.FileSystem) !*vfs.VNode {
        const file = try root.allocator.create(File);

        // TODO!: are data field, parent or kind field correctly put in file?
        file.* = .{
            .vnode = .{
                .vtable = &file_vtable,
                .filesystem = fs,
                .kind = .file,
                .name = "", // TODO
                .inode = allocInode(fs),
            },
        };

        return &file.vnode;
    }

    fn createDir(fs: *vfs.FileSystem) !*vfs.VNode {
        const dir = try root.allocator.create(Dir);

        dir.* = .{
            .vnode = .{
                .vtable = &dir_vtable,
                .filesystem = fs,
                .kind = .directory,
                .name = "", // TODO
                .inode = allocInode(fs),
            },
        };

        return &dir.vnode;
    }

    fn createSymlink(fs: *vfs.FileSystem, target: []const u8) !*vfs.VNode {
        const symlink = try root.allocator.create(vfs.VNode);
        errdefer root.allocator.destroy(symlink);

        symlink.* = .{
            .vtable = &.{},
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

pub fn init(name: []const u8, parent: ?*vfs.VNode) !*vfs.VNode {
    const fs = try root.allocator.create(FileSystem);

    fs.* = .{
        .filesystem = .{
            .vtable = &fs_vtable,
        },
        .root = .{
            .vnode = .{
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

    return &fs.root.vnode;
}
