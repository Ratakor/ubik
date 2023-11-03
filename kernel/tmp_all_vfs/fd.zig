const std = @import("std");
const sched = @import("sched.zig");

pub const FileDescriptor = struct {
    vtable: *const VTable,
    intern_fd: std.os.fd_t, // TODO
    fdflags: i32, // TODO
    status: i16, // TODO

    // TODO
    pub const VTable = struct {
        close: *const fn (std.os.fd_t) isize,
        fstat: *const anyopaque,
        read: *const anyopaque,
        write: *const anyopaque,
        lseek: *const anyopaque,
        dup: *const anyopaque,
        readDir: *const anyopaque,

        isatty: *const anyopaque,
        tcgetattr: *const anyopaque,
        tcsetattr: *const anyopaque,
        tcflow: *const anyopaque,
        getflflags: *const anyopaque,
        setflflags: *const anyopaque,
        perfmon_attach: *const anyopaque,
        unlink: *const anyopaque,
        getpath: *const anyopaque,
        recv: *const anyopaque,

        // TODO: this or set all field to @ptrCast(&stubFn)?
        pub const default = blk: {
            var stub: VTable = undefined;
            for (std.meta.fields(VTable)) |field| {
                @field(stub, field.name) = @ptrCast(&stubFn);
            }
            break :blk stub;
        };

        fn stubFn() isize {
            sched.setErrno(.NOSYS);
            return -1;
        }
    };

    pub fn create(self: *FileDescriptor) std.os.fd_t {
        _ = self;
    }

    pub inline fn close(self: *FileDescriptor) isize {
        return self.vtable.close(self.intern_fd);
    }
};
