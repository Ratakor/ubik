const std = @import("std");
const root = @import("root");
const log = std.log.scoped(.initramfs);

/// https://wiki.osdev.org/USTAR
const Tar = extern struct {
    name: [100]u8,
    mode: [7:0]u8,
    uid: [7:0]u8,
    gid: [7:0]u8,
    size: [11:0]u8,
    mtime: [11:0]u8,
    checksum: [8]u8,
    typeflag: TypeFlag,
    link_name: [100]u8,
    magic: [5:0]u8,
    version: [2]u8,
    uname: [32]u8,
    gname: [32]u8,
    dev_major: [8]u8,
    dev_minor: [8]u8,
    prefix: [155]u8,

    const TypeFlag = enum(u8) {
        normal = '0',
        hard_link = '1',
        symlink = '2',
        char_dev = '3',
        block_dev = '4',
        directory = '5',
        fifo = '6',
    };
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
