const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const SpinLock = @import("SpinLock.zig");
const serial = @import("serial.zig");

var log_lock: SpinLock = .{};

var fba_buffer: [16 * 1024 * 1024]u8 = undefined; // 16MiB
var debug_fba = std.heap.FixedBufferAllocator.init(&fba_buffer);
const debug_allocator = debug_fba.allocator();
var debug_info: ?std.dwarf.DwarfInfo = null;

pub fn init() !void {
    errdefer debug_info = null;
    const kernel_file = root.kernel_file_request.response.?.kernel_file;

    debug_info = .{
        .endian = .Little,
        .sections = .{
            .{ .data = try getSectionSlice(kernel_file.address, ".debug_info"), .owned = true },
            .{ .data = try getSectionSlice(kernel_file.address, ".debug_abbrev"), .owned = true },
            .{ .data = try getSectionSlice(kernel_file.address, ".debug_str"), .owned = true },
            null, // debug_str_offsets
            .{ .data = try getSectionSlice(kernel_file.address, ".debug_line"), .owned = true },
            null, // debug_line_str
            .{ .data = try getSectionSlice(kernel_file.address, ".debug_ranges"), .owned = true },
            null, // debug_loclists
            null, // debug_rnglists
            null, // debug_addr
            null, // debug_names
            null, // debug_frame
            null, // eh_frame
            null, // eh_frame_hdr
        },
        .is_macho = false,
    };

    try std.dwarf.openDwarfDebugInfo(&debug_info.?, debug_allocator);
}

pub fn printStackIterator(writer: anytype, stack_iter: std.debug.StackIterator) void {
    var iter = stack_iter;

    writer.print("Stack trace:\n", .{}) catch unreachable;
    while (iter.next()) |addr| {
        printSymbol(writer, addr);
    }
}

pub fn printStackTrace(writer: anytype, stack_trace: *std.builtin.StackTrace) void {
    var frame_index: usize = 0;
    var frames_left: usize = @min(stack_trace.index, stack_trace.instruction_addresses.len);

    writer.print("Stack trace:\n", .{}) catch unreachable;
    while (frames_left != 0) {
        const return_address = stack_trace.instruction_addresses[frame_index];
        printSymbol(writer, return_address);
        frames_left -= 1;
        frame_index = (frame_index + 1) % stack_trace.instruction_addresses.len;
    }
}

fn printSymbol(writer: anytype, address: u64) void {
    var symbol_name: []const u8 = "<no symbol info>";
    var file_name: []const u8 = "??";
    var line: usize = 0;

    if (debug_info) |*info| brk: {
        if (info.getSymbolName(address)) |name| {
            symbol_name = name;
        }

        const compile_unit = info.findCompileUnit(address) catch break :brk;
        const line_info = info.getLineNumberInfo(debug_allocator, compile_unit.*, address) catch break :brk;

        file_name = line_info.file_name;
        line = line_info.line;
    }

    writer.print("0x{x:0>16}: {s} at {s}:{d}\n", .{
        address,
        symbol_name,
        file_name,
        line,
    }) catch unreachable;
}

fn getSectionData(elf: [*]const u8, shdr: []const u8) []const u8 {
    const offset = std.mem.readIntLittle(u64, shdr[24..][0..8]);
    const size = std.mem.readIntLittle(u64, shdr[32..][0..8]);

    return elf[offset .. offset + size];
}

fn getSectionName(names: []const u8, shdr: []const u8) ?[]const u8 {
    const offset = std.mem.readIntLittle(u32, shdr[0..][0..4]);
    const len = std.mem.indexOf(u8, names[offset..], "\x00") orelse return null;

    return names[offset .. offset + len];
}

fn getShdr(elf: [*]const u8, idx: u16) []const u8 {
    const sh_offset = std.mem.readIntLittle(u64, elf[40 .. 40 + 8]);
    const sh_entsize = std.mem.readIntLittle(u16, elf[58 .. 58 + 2]);
    const off = sh_offset + sh_entsize * idx;

    return elf[off .. off + sh_entsize];
}

fn getSectionSlice(elf: [*]const u8, section_name: []const u8) ![]const u8 {
    const sh_strndx = std.mem.readIntLittle(u16, elf[62 .. 62 + 2]);
    const sh_num = std.mem.readIntLittle(u16, elf[60 .. 60 + 2]);

    if (sh_strndx > sh_num) {
        return error.ShstrndxOutOfRange;
    }

    const section_names = getSectionData(elf, getShdr(elf, sh_strndx));

    var i: u16 = 0;

    while (i < sh_num) : (i += 1) {
        const header = getShdr(elf, i);

        if (std.mem.eql(u8, getSectionName(section_names, header) orelse continue, section_name)) {
            return getSectionData(elf, header);
        }
    }

    return error.SectionNotFound;
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    comptime if (builtin.mode != .Debug) return;

    const level_txt = comptime switch (level) {
        .err => "\x1b[31merror\x1b[m",
        .warn => "\x1b[33mwarning\x1b[m",
        .info => "\x1b[32minfo\x1b[m",
        .debug => "\x1b[36mdebug\x1b[m",
    };
    const scope_prefix = (if (scope != .default) "@" ++ @tagName(scope) else "") ++ ": ";

    log_lock.lock();
    defer log_lock.unlock();
    const fmt = level_txt ++ scope_prefix ++ format ++ "\n";
    nosuspend serial.print(fmt, args);
}
