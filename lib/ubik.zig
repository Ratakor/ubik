//! https://pubs.opengroup.org/onlinepubs/9699919799/

const std = @import("std");
const linux = std.os.linux;

pub const PATH_MAX = 4096;
pub const STDIN_FILENO = 0;
pub const STDOUT_FILENO = 1;
pub const STDERR_FILENO = 2;

pub const T = linux.T;
pub const S = linux.S;
pub const E = linux.E;
pub const PROT = linux.PROT;
pub const MAP = linux.MAP;
pub const DT = linux.DT;
pub const O = linux.O;
pub const SIG = linux.SIG;

// TODO: rename those the zig way?
pub const blkcnt_t = linux.blkcnt_t;
pub const blksize_t = linux.blksize_t;
pub const clock_t = linux.clock_t;
pub const clockid_t = i32;
pub const dev_t = linux.dev_t;
pub const fsblkcnt_t = u64;
pub const fsfilcnt_t = u64;
pub const gid_t = linux.gid_t;
pub const id_t = u32;
pub const ino_t = linux.ino_t;
pub const key_t = i32;
pub const mode_t = linux.mode_t;
pub const nlink_t = linux.nlink_t;
pub const off_t = linux.off_t;
pub const pid_t = linux.pid_t;
pub const size_t = usize;
pub const ssize_t = isize;
pub const suseconds_t = i64;
pub const time_t = linux.time_t;
pub const timer_t = *anyopaque;
pub const uid_t = linux.uid_t;

pub const fd_t = linux.fd_t;

pub const Stat = extern struct {
    /// device
    dev: dev_t,
    /// file serial number
    ino: ino_t,
    /// file mode
    mode: mode_t,
    /// hard link count
    nlink: nlink_t,
    /// user id of the owner
    uid: uid_t,
    /// group id of the owner
    gid: gid_t,
    /// device number, if device
    rdev: dev_t,
    /// size of file in bytes or length of target pathname for symlink
    size: off_t,
    /// optimal block size for I/O
    blksize: blksize_t,
    /// number of 512-byte block allocated
    blocks: blkcnt_t,
    /// time of last access
    atim: timespec,
    /// time of last modification
    mtim: timespec,
    /// time of last status change
    ctim: timespec,

    /// time of file creation
    birthtim: timespec,
};

pub const dirent = extern struct {
    ino: ino_t,
    off: off_t,
    reclen: u16,
    type: u8,
    name: [255:0]u8,
};

pub const timespec = extern struct {
    sec: time_t = 0,
    nsec: isize = 0,

    pub const max_ns = std.time.ns_per_s - 1;

    pub inline fn add(self: *timespec, ts: timespec) void {
        if (self.nsec + ts.nsec > max_ns) {
            self.nsec = self.nsec + ts.nsec - std.time.ns_per_s;
            self.sec += 1;
        } else {
            self.nsec += ts.nsec;
        }
        self.sec += ts.sec;
    }

    pub inline fn sub(self: *timespec, ts: timespec) void {
        if (ts.nsec > self.nsec) {
            self.nsec = max_ns - (ts.nsec - self.nsec);
            if (self.sec == 0) {
                self.nsec = 0;
                return;
            }
            self.sec -= 1;
        } else {
            self.nsec -= ts.nsec;
        }

        if (ts.sec > self.sec) {
            self.sec = 0;
            self.nsec = 0;
        } else {
            self.sec -= ts.sec;
        }
    }
};
