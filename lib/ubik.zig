const std = @import("std");
const linux = std.os.linux;

pub const T = linux.T;
pub const S = linux.S;
pub const E = linux.E;
pub const PROT = linux.PROT;
pub const MAP = linux.MAP;
pub const DT = linux.DT;
pub const O = linux.O;

pub const ino_t = linux.ino_t;
pub const off_t = linux.off_t;
pub const dev_t = linux.dev_t;
pub const mode_t = linux.mode_t;
pub const pid_t = linux.pid_t;
pub const fd_t = linux.fd_t;
pub const uid_t = linux.uid_t;
pub const gid_t = linux.gid_t;
pub const clock_t = linux.clock_t;
pub const time_t = linux.time_t;
pub const nlink_t = linux.nlink_t;
pub const blksize_t = linux.blksize_t;
pub const blkcnt_t = linux.blkcnt_t;

// TODO: change undefined initializers
pub const Stat = extern struct {
    /// device
    dev: dev_t = undefined,
    /// file serial number
    ino: ino_t = undefined,
    /// file mode
    mode: mode_t = 0o666,
    /// hard link count
    nlink: nlink_t = 0,
    /// user id of the owner
    uid: uid_t = 0,
    /// group id of the owner
    gid: gid_t = 0,
    /// device number, if device
    rdev: dev_t = undefined,
    /// size of file in bytes
    size: off_t = 0,
    /// optimal block size for I/O
    blksize: blksize_t = undefined,
    /// number of 512-byte block allocated
    blocks: blkcnt_t = 0,
    /// time of last access
    atim: timespec = .{},
    /// time of last modification
    mtim: timespec = .{},
    /// time of last status change
    ctim: timespec = .{},
};

// TODO: initializers
pub const DirectoryEntry = extern struct {
    ino: ino_t,
    off: off_t,
    reclen: u16,
    type: u8,
    name: [255:0]u8 = undefined,
};

pub const timespec = extern struct {
    tv_sec: isize = 0,
    tv_nsec: isize = 0,

    pub const max_ns = std.time.ns_per_s - 1;

    pub inline fn add(self: *timespec, ts: timespec) void {
        if (self.tv_nsec + ts.tv_nsec > max_ns) {
            self.tv_nsec = (self.tv_nsec + ts.tv_nsec) - std.time.ns_per_s;
            self.tv_sec += 1;
        } else {
            self.tv_nsec += ts.tv_nsec;
        }
        self.tv_sec += ts.tv_sec;
    }

    pub inline fn sub(self: *timespec, ts: timespec) void {
        if (ts.tv_nsec > self.tv_nsec) {
            self.tv_nsec = max_ns - (ts.tv_nsec - self.tv_nsec);
            if (self.tv_sec == 0) {
                self.tv_nsec = 0;
                return;
            }
            self.tv_sec -= 1;
        } else {
            self.tv_nsec -= ts.tv_nsec;
        }

        if (ts.tv_sec > self.tv_sec) {
            self.tv_sec = 0;
            self.tv_nsec = 0;
        } else {
            self.tv_sec -= ts.tv_sec;
        }
    }
};
