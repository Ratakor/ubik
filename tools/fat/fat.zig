const std = @import("std");
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const mem = std.mem;
const os = std.os;
const process = std.process;

const BootSector = packed struct {
    boot_jump_instruction: u24, // [3]u8
    oem_identifier: u64, // [8]u8
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    reserved_sectors: u16,
    fat_count: u8,
    dir_entry_count: u16,
    total_sectors: u16,
    media_descriptor_type: u8,
    sectors_per_fat: u16,
    sectors_per_track: u16,
    heads: u16,
    hidden_sectors: u32,
    large_sector_count: u32,

    // extended boot record
    drive_number: u8,
    _reserved: u8,
    signature: u8,
    volume_id: u32, // serial number, value doesn't matter
    volume_label: u88, // [11]u8 // 11 bytes, padded with space
    system_id: u64, // [8]u8
};

const DirectoryEntry = extern struct {
    name: [11]u8 align(1),
    attributes: u8 align(1),
    _reserved: u8 align(1),
    created_time_tenths: u8 align(1),
    created_time: u16 align(1),
    created_date: u16 align(1),
    accessed_date: u16 align(1),
    first_cluster_high: u16 align(1),
    modified_time: u16 align(1),
    modified_date: u16 align(1),
    first_cluster_low: u16 align(1),
    size: u32 align(1),
};

var gpa = heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
var progname: [:0]const u8 = undefined;

var boot_sector: BootSector = undefined;
var fat_buf: []u8 = undefined;
var root_directory: []DirectoryEntry = undefined;
var root_directory_end: u32 = undefined;

fn die(status: u8, comptime fmt: []const u8, args: anytype) noreturn {
    const stderr = io.getStdErr().writer();
    stderr.print("{s}: ", .{progname}) catch {};
    stderr.print(fmt, args) catch {};
    os.exit(status);
}

fn readFat(disk: fs.File, reader: anytype) !void {
    fat_buf = try allocator.alloc(u8, boot_sector.sectors_per_fat * boot_sector.bytes_per_sector);
    errdefer allocator.free(fat_buf);
    const lba = boot_sector.reserved_sectors;
    try disk.seekTo(lba * boot_sector.bytes_per_sector);
    if (try reader.readAll(fat_buf) != fat_buf.len) {
        return error.ReadFatError;
    }
}

fn readRootDirectory(disk: fs.File, reader: anytype) !void {
    const lba = boot_sector.reserved_sectors + boot_sector.sectors_per_fat * boot_sector.fat_count;
    const size = @sizeOf(DirectoryEntry) * boot_sector.dir_entry_count;
    var sectors = size / boot_sector.bytes_per_sector;
    if (@mod(size, boot_sector.bytes_per_sector) > 0) {
        sectors += 1;
    }

    root_directory_end = lba + sectors;
    root_directory = try allocator.alloc(DirectoryEntry, boot_sector.dir_entry_count);
    errdefer allocator.free(root_directory);
    try disk.seekTo(lba * boot_sector.bytes_per_sector);
    for (0..boot_sector.dir_entry_count) |i| {
        root_directory[i] = try reader.readStruct(DirectoryEntry);
    }
}

fn findFile(name: []const u8) ?*DirectoryEntry {
    for (0..boot_sector.dir_entry_count) |i| {
        if (mem.eql(u8, name, &root_directory[i].name)) {
            return &root_directory[i];
        }
    }
    return null;
}

fn readFile(file_entry: *DirectoryEntry, disk: fs.File, reader: anytype, buf: []u8) !void {
    var current_cluster = file_entry.first_cluster_low;
    var i: usize = 0;

    while (current_cluster < 0x0FF8) {
        const lba = root_directory_end + (current_cluster -% 2) * boot_sector.sectors_per_cluster;
        try disk.seekTo(lba * boot_sector.bytes_per_sector);
        if (try reader.readAll(buf[i..]) != buf.len) {
            return;
        }
        i += boot_sector.sectors_per_cluster * boot_sector.bytes_per_sector;

        const idx = current_cluster * 3 / 2; // - 1 ?
        if (current_cluster % 2 == 0) {
            current_cluster = mem.readIntSliceNative(u16, fat_buf[idx..]) & 0x0FFF;
        } else {
            current_cluster = mem.readIntSliceNative(u16, fat_buf[idx..]) >> 4;
        }
    }
}

inline fn isprint(c: u8) bool {
    return c -% 0x20 < 0x5f;
}

fn usage() noreturn {
    const stderr = io.getStdErr().writer();
    stderr.print("usage: {s} <disk image> <file name>\n", .{progname}) catch {};
    os.exit(1);
}

// zig build-exe fat.zig && ./fat ../../build/floppy.img "TEST    TXT"
pub fn main() !void {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    progname = args.next().?;

    const diskname = args.next() orelse usage();
    var disk = fs.cwd().openFileZ(diskname, .{ .mode = .read_only }) catch |err| {
        die(1, "cannot open disk image \"{s}\": {s}\n", .{diskname, @errorName(err)});
    };
    var disk_br = io.bufferedReader(disk.reader());
    const disk_reader = disk_br.reader();

    boot_sector = disk_reader.readStruct(BootSector) catch |err| {
        die(2, "couldn't read boot sector: {s}\n", .{@errorName(err)});
    };

    readFat(disk, disk_reader) catch |err| {
        die(3, "couldn't read FAT: {s}\n", .{@errorName(err)});
    };
    defer allocator.free(fat_buf);

    readRootDirectory(disk, disk_reader) catch |err| {
        die(4, "couldn't read FAT: {s}\n", .{@errorName(err)});
    };
    defer allocator.free(root_directory);

    const filename = args.next() orelse usage();
    const file_entry: *DirectoryEntry = findFile(filename) orelse {
        die(5, "couldn't find file \"{s}\" in FAT\n", .{filename});
    };

    var buf = try allocator.alloc(u8, file_entry.size + boot_sector.bytes_per_sector);
    defer allocator.free(buf);
    readFile(file_entry, disk, disk_reader, buf) catch |err| {
        die(6, "couldn't read file \"{s}\": {s}\n", .{filename, @errorName(err)});
    };

    var bw = io.bufferedWriter(io.getStdOut().writer());
    const stdout = bw.writer();

    for (0..file_entry.size) |i| {
        if (isprint(buf[i])) {
            try stdout.writeByte(buf[i]);
        } else {
            try stdout.print("<{x:0>2}>", .{buf[i]});
        }
    }
    try stdout.writeAll("\n");
    try bw.flush();
}
