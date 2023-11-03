const std = @import("std");
const linux = std.os.linux;

pub const T = linux.T;
pub const S = linux.S;
pub const E = linux.E;
pub const PROT = linux.PROT;
pub const MAP = linux.MAP;
pub const DT = linux.DT;
pub const O = linux.O;

pub const off_t = linux.off_t;
pub const dev_t = linux.dev_t;
pub const mode_t = linux.mode_t;
pub const pid_t = linux.pid_t;
pub const fd_t = linux.fd_t;
pub const uid_t = linux.uid_t;
pub const gid_t = linux.gid_t;
pub const clock_t = linux.clock_t;
pub const time_t = linux.time_t;

pub const Stat = linux.Stat;
pub const DirectoryEntry = extern struct {
    ino: u64,
    off: u64,
    reclen: u16,
    type: u8,
    name: [255:0]u8,
};
