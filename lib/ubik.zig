const std = @import("std");
const linux = std.os.linux;

pub const T = linux.T;
pub const S = linux.S;
pub const E = linux.E;
pub const PROT = linux.PROT;
pub const MAP = linux.MAP;
pub const Stat = linux.Stat;
pub const DirectoryEntry = linux.dirent64;
pub const DT = linux.DT;
pub const O = linux.O;
pub const dev_t = linux.dev_t;

pub const term = @import("term.zig");
