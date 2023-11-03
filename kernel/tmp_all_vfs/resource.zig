const std = @import("std");
const root = @import("root");
const sched = @import("sched.zig");
const ev = @import("event.zig");
const vfs = @import("vfs.zig");
const SpinLock = root.SpinLock;

// TODO: merge with vfs
// TODO: replace -1 returns and wrong bool with correct error

pub const Resource = struct {
    res_size: usize,
    status: i32,
    event: ev.Event,
    refcount: usize,
    lock: SpinLock,
    stat: std.os.Stat,
    can_mmap: bool,

    read: *const fn (self: *Resource, description: *FileDescription, buf: *anyopaque, offset: isize, count: usize) isize,
    write: *const fn (self: *Resource, description: *FileDescription, buf: *const anyopaque, offset: isize, count: usize) isize,
    ioctl: *const fn (self: *Resource, description: *FileDescription, request: u64, arg: u64) i32,
    mmap: *const fn (self: *Resource, file_page: usize, flags: i32) *anyopaque,
    msync: *const fn (self: *Resource, file_page: usize, phys: *anyopaque, flags: i32) bool,
    chmod: *const fn (self: *Resource, mode: u32) bool,
    unref: *const fn (self: *Resource, description: *FileDescription) bool,
    ref: *const fn (self: *Resource, description: *FileDescription) bool,
    truncate: *const fn (self: *Resource, description: *FileDescription, length: usize) bool,

    fn default_ioctl(self: *Resource, description: *FileDescription, request: u64, arg: u64) i32 {
        _ = arg;
        _ = description;
        _ = self;

        const T = std.os.T;
        switch (request) {
            T.CGETS, T.CSETS, T.IOCSCTTY, T.IOCGWINSZ => sched.setErrno(.NOTTY),
            else => sched.setErrno(.INVAL),
        }
        return -1;
    }

    fn stub_read(self: *Resource, description: *FileDescription, buf: *anyopaque, offset: isize, count: usize) isize {
        _ = count;
        _ = offset;
        _ = buf;
        _ = description;
        _ = self;

        sched.setErrno(.NOSYS);
        return -1;
    }

    fn stub_write(self: *Resource, description: *FileDescription, buf: *const anyopaque, offset: isize, count: usize) isize {
        _ = count;
        _ = offset;
        _ = buf;
        _ = description;
        _ = self;

        sched.setErrno(.NOSYS);
        return -1;
    }

    fn stub_mmap(self: *Resource, file_page: usize, flags: i32) ?*anyopaque {
        _ = flags;
        _ = file_page;
        _ = self;

        sched.setErrno(.NOSYS);
        return null;
    }

    fn stub_msync(self: *Resource, file_page: usize, phys: *anyopaque, flags: i32) bool {
        _ = flags;
        _ = phys;
        _ = file_page;
        _ = self;

        sched.setErrno(.NOSYS);
        return false;
    }

    // TODO
    fn stub_chmod(self: *Resource, mode: u32) bool {
        self.stat.mode &= ~0o777;
        self.stat.mode |= mode & 0o777;
        return true;
    }

    fn stub_ref(self: *Resource, description: *FileDescription) bool {
        _ = description;

        self.refcount += 1;
        return true;
    }

    fn stub_unref(self: *Resource, description: *FileDescription) bool {
        _ = description;

        self.refcount -= 1;
        return true;
    }

    fn stub_truncate(self: *Resource, description: *FileDescription, length: usize) bool {
        _ = length;
        _ = description;
        _ = self;

        sched.setErrno(.NOSYS);
        return false;
    }

    // TODO
    pub fn init(size: usize) !*Resource {
        // const res = try root.allocator.create(Resource);
        const res: *Resource = @ptrCast(@alignCast(try root.allocator.alloc(u8, size)));

        res.* = .{
            .res_size = size,
            .status = undefined,
            .event = .{ .listeners = undefined }, // TODO
            .refcount = 0,
            .lock = .{},
            .stat = undefined, // TODO
            .can_mmap = undefined, // TODO
            .read = stub_read,
            .write = stub_write,
            .ioctl = default_ioctl,
            .mmap = stub_mmap,
            .msync = stub_msync,
            .chmod = stub_chmod,
            .ref = stub_ref,
            .unref = stub_unref,
            .truncate = stub_truncate,
        };

        return res;
    }

    pub fn deinit(self: *Resource) void {
        root.allocator.free(@as([*]u8, @ptrCast(@alignCast(self)))[0..self.res_size]);
    }
};

pub const FileDescription = struct {
    refcount: usize,
    offset: isize,
    is_dir: bool,
    flags: i32,
    lock: SpinLock,
    res: *Resource,
    node: *vfs.VNode,
};

pub const FileDescriptor = struct {
    description: *FileDescription,
    flags: i32,
};

// TODO
const O = std.os.O;
const FILE_CREATION_FLAGS_MASK = O.CREAT | O.DIRECTORY | O.EXCL | O.NOCTTY | O.NOFOLLOW | O.TRUNC;
const FILE_DESCRIPTOR_FLAGS_MASK = O.CLOEXEC;
const FILE_STATUS_FLAGS_MASK = ~(FILE_CREATION_FLAGS_MASK | FILE_DESCRIPTOR_FLAGS_MASK);

var dev_id_counter = std.atomic.Atomic(std.os.dev_t).init(1);

pub fn createDevID() std.os.dev_t {
    return dev_id_counter.fetchAdd(1, .Release);
}

pub fn fdnum_close(process: ?*sched.Process, fdnum: i32, lock: bool) bool {
    const proc = if (process) |p| p else sched.currentThread().process;

    if (lock) proc.fds_lock.lock();
    defer if (lock) proc.fds_lock.unlock();

    if (fdnum < 0 or fdnum >= sched.Process.max_fds) {
        sched.setErrno(.BADF);
        return false;
    }

    const fd = proc.fds[fdnum] orelse {
        sched.setErrno(.BADF);
        return false;
    };

    fd.description.res.unref(fd.description.res, fd.description); // TODO make this nicer

    fd.description.refcount -= 1;
    if (fd.description.refcount == 0) {
        root.allocator.destroy(fd.description);
    }
    root.allocator.destroy(fd);
    proc.fds[fdnum] = null;

    return true;
}

pub fn fdnum_create_from_fd(
    process: ?*sched.Process,
    fd: *FileDescriptor,
    old_fdnum: i32,
    specific: bool,
) i32 {
    const proc = if (process) |p| p else sched.currentThread().process;

    proc.fds_lock.lock();
    defer proc.fds_lock.unlock();

    if (old_fdnum < 0 or old_fdnum >= sched.Process.max_fds) {
        sched.setErrno(.BADF);
        return -1;
    }

    if (!specific) {
        for (old_fdnum..sched.Process.max_fds) |i| {
            if (proc.fds[i] == null) {
                proc.fds[i] = fd;
                return i;
            }
        } else {
            return -1;
        }
    } else {
        fdnum_close(proc, old_fdnum, false);
        proc.fds[old_fdnum] = fd;
        return old_fdnum;
    }
}

pub fn fdnum_create_from_resource(
    process: ?*sched.Process,
    res: *Resource,
    flags: i32,
    old_fdnum: i32,
    specific: bool,
) i32 {
    const fd = fd_create_from_resource(res, flags) orelse return -1;
    return fdnum_create_from_fd(process, fd, old_fdnum, specific);
}

pub fn fdnum_dup(
    old_process: ?*sched.Process,
    old_fdnum: i32,
    new_process: ?*sched.Process,
    new_fdnum: i32,
    flags: i32,
    specific: bool,
    cloexec: bool,
) i32 {
    const old_proc = if (old_process) |op| op else sched.currentThread().process;
    const new_proc = if (new_process) |np| np else sched.currentThread().process;

    if (specific and old_fdnum == new_fdnum and old_proc == new_proc) {
        sched.setErrno(.INVAL);
        return -1;
    }

    const old_fd = fd_from_fdnum(old_proc, old_fdnum) orelse return -1;
    const new_fd = root.allocator.create(FileDescriptor) catch {
        sched.setErrno(.NOMEM); // TODO: set errno in vmm.alloc directly?
        return -1;
    };
    errdefer root.allocator.destroy(new_fd);
    new_fd.* = old_fd.*;

    const dup_fdnum = fdnum_create_from_fd(new_proc, new_fd, new_fdnum, specific);
    if (dup_fdnum < 0) return -1; // TODO return error to destroy new_fd

    // TODO: a little dumb
    new_fd.flags = flags & FILE_DESCRIPTOR_FLAGS_MASK;
    if (cloexec) {
        new_fd.flags &= O.CLOEXEC;
    }

    old_fd.description.refcount += 1;
    old_fd.description.res.ref(old_fd.description.res, old_fd.description);

    return dup_fdnum;
}

pub fn fd_create_from_resource(res: *Resource, flags: i32) ?*FileDescriptor {
    const description = root.allocator.create(FileDescription) catch return null;
    // errdefer root.allocator.destroy(description);

    description.refcount = 1;
    description.flags = flags & FILE_STATUS_FLAGS_MASK;
    description.lock = .{};
    description.res = res;

    const fd = root.allocator.create(FileDescriptor) catch return null;
    res.ref(res, description);
    fd.description = description;
    fd.flags = flags & FILE_DESCRIPTOR_FLAGS_MASK;

    return fd;
}

pub fn fd_from_fdnum(process: ?*sched.Process, fdnum: i32) ?*FileDescriptor {
    const proc = if (process) |p| p else sched.currentThread().process;

    proc.lock.lock();
    defer proc.lock.unlock();

    if (fdnum < 0 or fdnum >= sched.Process.max_fds) {
        sched.setErrno(.BADF);
        return null;
    }

    if (proc.fds[fdnum]) |fd| {
        fd.description.refcount += 1;
        return fd;
    } else {
        sched.setErrno(.BADF);
        return null;
    }
}
