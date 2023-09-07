const std = @import("std");
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const mem = std.mem;
const os = std.os;
const process = std.process;

const BootSector = extern struct {
    boot_jump_instruction: [3]u8 align(1),
    oem_identifier: [8]u8 align(1),
    bytes_per_sector: u16 align(1),
    sectors_per_cluster: u8 align(1),
    reserved_sectors: u16 align(1),
    fat_count: u8 align(1),
    dir_entry_count: u16 align(1),
    total_sectors: u16 align(1),
    media_descriptor_type: u8 align(1),
    sectors_per_fat: u16 align(1),
    sectors_per_track: u16 align(1),
    heads: u16 align(1),
    hidden_sectors: u32 align(1),
    large_sector_count: u32 align(1),

    // extended boot record
    drive_number: u8 align(1),
    _reserved: u8 align(1),
    signature: u8 align(1),
    volume_id: u32 align(1), // serial number, value doesn't matter
    volume_label: [11]u8 align(1), // 11 bytes, padded with space
    system_id: [8]u8 align(1),
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
var root_directory_end: u32 = undefined;

fn die(status: u8, comptime fmt: []const u8, args: anytype) noreturn {
    const stderr = io.getStdErr().writer();
    stderr.print("{s}: ", .{progname}) catch {};
    stderr.print(fmt, args) catch {};
    os.exit(status);
}

fn readFat(disk: fs.File) ![]u8 {
    const size = boot_sector.sectors_per_fat * boot_sector.bytes_per_sector;
    var fat = try allocator.alloc(u8, size);
    errdefer allocator.free(fat);
    const lba = boot_sector.reserved_sectors;
    try disk.seekTo(lba * boot_sector.bytes_per_sector);
    if (try disk.reader().readAll(fat) != fat.len) {
        return error.ReadFatError;
    }
    return fat;
}

fn readRootDirectory(disk: fs.File) ![]DirectoryEntry {
    const lba = boot_sector.reserved_sectors + boot_sector.sectors_per_fat * boot_sector.fat_count;
    const size = @sizeOf(DirectoryEntry) * boot_sector.dir_entry_count;
    var sectors = size / boot_sector.bytes_per_sector;
    if (@mod(size, boot_sector.bytes_per_sector) > 0) {
        sectors += 1;
    }

    root_directory_end = lba + sectors;
    var root_directory = try allocator.alloc(DirectoryEntry, boot_sector.dir_entry_count);
    errdefer allocator.free(root_directory);
    try disk.seekTo(lba * boot_sector.bytes_per_sector);
    var br = io.bufferedReader(disk.reader());
    const reader = br.reader();
    for (0..boot_sector.dir_entry_count) |i| {
        root_directory[i] = try reader.readStruct(DirectoryEntry);
    }
    return root_directory;
}

fn findFile(root_directory: []DirectoryEntry, file_name: []const u8) ?*DirectoryEntry {
    for (0..boot_sector.dir_entry_count) |i| {
        if (mem.eql(u8, file_name, &root_directory[i].name)) {
            return &root_directory[i];
        }
    }
    return null;
}

fn readFile(file_entry: *DirectoryEntry, disk: fs.File, fat: []u8) ![]u8 {
    var buf = try allocator.alloc(u8, file_entry.size + boot_sector.bytes_per_sector);
    errdefer allocator.free(buf);
    var current_cluster = file_entry.first_cluster_low;
    var i: usize = 0;

    while (current_cluster < 0x0FF8) {
        const lba = root_directory_end + (current_cluster -% 2) * boot_sector.sectors_per_cluster;
        try disk.seekTo(lba * boot_sector.bytes_per_sector);
        if (try disk.reader().readAll(buf[i..]) != buf.len) {
            return error.ReadFileError;
        }
        i += boot_sector.sectors_per_cluster * boot_sector.bytes_per_sector;

        const idx = current_cluster * 3 / 2; // - 1 ?
        if (current_cluster % 2 == 0) {
            current_cluster = mem.readIntSliceNative(u16, fat[idx..]) & 0x0FFF;
        } else {
            current_cluster = mem.readIntSliceNative(u16, fat[idx..]) >> 4;
        }
    }

    return buf;
}

inline fn isprint(c: u8) bool {
    return c -% 0x20 < 0x5f;
}

fn usage() noreturn {
    const stderr = io.getStdErr().writer();
    stderr.print("usage: {s} <disk image> <file name>\n", .{progname}) catch {};
    os.exit(1);
}

pub fn main() !void {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    progname = args.next().?;

    const diskname = args.next() orelse usage();
    var disk = fs.cwd().openFile(diskname, .{ .mode = .read_only }) catch |err| {
        die(1, "cannot open disk image \"{s}\": {s}\n", .{ diskname, @errorName(err) });
    };

    boot_sector = disk.reader().readStruct(BootSector) catch |err| {
        die(2, "couldn't read boot sector: {s}\n", .{@errorName(err)});
    };

    const fat = readFat(disk) catch |err| {
        die(3, "couldn't read FAT: {s}\n", .{@errorName(err)});
    };
    defer allocator.free(fat);

    const root_directory = readRootDirectory(disk) catch |err| {
        die(4, "couldn't read root directory: {s}\n", .{@errorName(err)});
    };
    defer allocator.free(root_directory);

    const file_name = args.next() orelse usage();
    const file_entry = findFile(root_directory, file_name) orelse {
        die(5, "couldn't find file \"{s}\" in FAT\n", .{file_name});
    };

    const file = readFile(file_entry, disk, fat) catch |err| {
        die(6, "couldn't read file \"{s}\": {s}\n", .{ file_name, @errorName(err) });
    };
    defer allocator.free(file);

    var bw = io.bufferedWriter(io.getStdOut().writer());
    const stdout = bw.writer();
    for (0..file_entry.size) |i| {
        if (isprint(file[i])) {
            try stdout.writeByte(file[i]);
        } else {
            try stdout.print("<{x:0>2}>", .{file[i]});
        }
    }
    try stdout.writeAll("\n");
    try bw.flush();
}
