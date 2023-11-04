const std = @import("std");
const root = @import("root");
const log = std.log.scoped(.initramfs);

/// https://wiki.osdev.org/USTAR
/// If the first byte of `prefix` is 0, the file name is `name` otherwise it is `prefix/name`
const Tar = extern struct {
    name: [99:0]u8, // can be 100 bytes long with no sentinel
    mode: [8]u8,
    uid: [8]u8,
    gid: [8]u8,
    size: [12]u8,
    mtime: [12]u8,
    checksum: [8]u8,
    type_flag: std.tar.Header.FileType,
    link_name: [99:0]u8, // can be 100 bytes long with no sentinel
    magic: [5:0]u8,
    version: [2]u8,
    uname: [31:0]u8,
    gname: [31:0]u8,
    dev_major: [8]u8,
    dev_minor: [8]u8,
    prefix: [154:0]u8, // can be 155 bytes long with no sentinel

    comptime {
        std.debug.assert(@sizeOf(Tar) == 500);
    }
};

pub fn init() void {
    const modules = (root.module_request.response orelse return).modules();
    log.info("found {} modules at 0x{x}", .{ modules.len, @intFromPtr(modules.ptr) });

    for (modules) |module| {
        const tar: *Tar = @ptrCast(module.address);
        if (!std.mem.eql(u8, tar.magic[0..], "ustar")) continue;

        // TODO
        log.debug("file {*} is a tar", .{module.address});

        // TODO
        const mode = std.fmt.parseUnsigned(u64, tar.mode[0..], 8) catch unreachable;
        const uid = std.fmt.parseUnsigned(u64, tar.uid[0..], 8) catch unreachable;
        const gid = std.fmt.parseUnsigned(u64, tar.gid[0..], 8) catch unreachable;
        const size = std.fmt.parseUnsigned(u64, tar.size[0..], 8) catch unreachable;
        const mtime = std.fmt.parseUnsigned(u64, tar.mtime[0..], 8) catch unreachable;
        _ = mode;
        _ = uid;
        _ = gid;
        _ = size;
        _ = mtime;
    }
}
