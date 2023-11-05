const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const arch = @import("arch.zig");
const serial = @import("serial.zig");
const smp = @import("smp.zig");
const time = @import("time.zig");
const SpinLock = root.SpinLock;
const StackIterator = std.debug.StackIterator;

var log_lock: SpinLock = .{};
var panic_lock: SpinLock = .{};

var fba_buffer: [32 * 1024 * 1024]u8 = undefined; // 32MiB
var debug_fba = std.heap.FixedBufferAllocator.init(&fba_buffer);
const debug_allocator = debug_fba.allocator();
var debug_info: ?std.dwarf.DwarfInfo = null;

var dmesg = blk: {
    var dmesg_sfa = std.heap.stackFallback(4096, root.allocator);
    break :blk std.ArrayList(u8).init(dmesg_sfa.get());
};
const dmesg_writer = dmesg.writer();

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    @setCold(true);

    arch.disableInterrupts();

    if (!panic_lock.tryLock()) {
        arch.halt();
    }

    smp.stopAll();

    const fmt = "\x1b[m\x1b[31m\nKernel panic:\x1b[m {s}\n";
    const stack_iter = StackIterator.init(ret_addr orelse @returnAddress(), @frameAddress());

    dmesg_writer.print(fmt, .{msg}) catch {};
    printStackIterator(dmesg_writer, stack_iter);

    if (root.tty0) |tty| {
        const writer = tty.writer();
        writer.print(fmt, .{msg}) catch {};
        printStackIterator(writer, stack_iter);
        root.term.hideCursor(writer) catch {};
    } else {
        serial.print(fmt, .{msg});
        printStackIterator(serial.writer, stack_iter);
    }

    arch.halt();
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime switch (level) {
        .err => "\x1b[31merror\x1b[m",
        .warn => "\x1b[33mwarning\x1b[m",
        .info => "\x1b[32minfo\x1b[m",
        .debug => "\x1b[36mdebug\x1b[m",
    };
    const scope_prefix = (if (scope != .default) "@" ++ @tagName(scope) else "") ++ ": ";
    const fmt = level_txt ++ scope_prefix ++ format ++ "\n";

    log_lock.lock();
    defer log_lock.unlock();

    if (comptime scope != .gpa) {
        dmesg_writer.print("[{d: >5}.{d:0>6}] ", .{
            @as(usize, @intCast(time.monotonic.tv_sec)),
            @as(usize, @intCast(time.monotonic.tv_nsec)) / std.time.ns_per_ms,
        }) catch {};
        dmesg_writer.print(fmt, args) catch {};
    }

    if (comptime builtin.mode == .Debug) {
        serial.print("[{d: >5}.{d:0>6}] ", .{
            @as(usize, @intCast(time.monotonic.tv_sec)),
            @as(usize, @intCast(time.monotonic.tv_nsec)) / std.time.ns_per_ms,
        });
        serial.print(fmt, args);
    }
}

fn printStackIterator(writer: anytype, stack_iter: StackIterator) void {
    if (builtin.strip_debug_info) {
        writer.writeAll("Unable to dump stack trace: Debug info stripped\n") catch {};
        return;
    }
    if (debug_info == null) {
        initDebugInfo() catch |err| {
            writer.print("Unable to dump stack trace: Unable to init debug info: {s}\n", .{@errorName(err)}) catch {};
            return;
        };
    }

    var iter = stack_iter;
    while (iter.next()) |return_address| {
        const address = if (return_address == 0) continue else return_address - 1;
        printSymbolInfo(writer, address) catch |err| {
            writer.print("Unable to dump stack trace: {s}\n", .{@errorName(err)}) catch {};
            return;
        };
    }
}

fn printSymbolInfo(writer: anytype, address: u64) !void {
    const symbol_info: std.debug.SymbolInfo = if (debug_info.?.findCompileUnit(address)) |compile_unit| .{
        .symbol_name = debug_info.?.getSymbolName(address) orelse "???",
        .compile_unit_name = compile_unit.die.getAttrString(
            &debug_info.?,
            std.dwarf.AT.name,
            debug_info.?.section(.debug_str),
            compile_unit.*,
        ) catch "???",
        .line_info = debug_info.?.getLineNumberInfo(debug_allocator, compile_unit.*, address) catch |err| switch (err) {
            error.MissingDebugInfo, error.InvalidDebugInfo => null,
            else => return err,
        },
    } else |err| switch (err) {
        error.MissingDebugInfo, error.InvalidDebugInfo => .{},
        else => return err,
    };
    defer symbol_info.deinit(debug_allocator);

    if (symbol_info.line_info) |li| {
        try writer.print("\x1b[1m{s}:{d}:{d}\x1b[m: \x1b[2m0x{x:0>16} in {s} ({s})\x1b[m\n", .{
            li.file_name,
            li.line,
            li.column,
            address,
            symbol_info.symbol_name,
            symbol_info.compile_unit_name,
        });

        if (printLineFromFile(writer, li)) {
            if (li.column > 0) {
                try writer.writeByteNTimes(' ', li.column - 1);
                try writer.writeAll("\x1b[32m^\x1b[m");
            }
            try writer.writeAll("\n");
        } else |err| switch (err) {
            error.EndOfFile, error.FileNotFound => {},
            else => return err,
        }
    } else {
        try writer.print("\x1b[1m???:?:?\x1b[m: \x1b[2m0x{x:0>16} in {s} ({s})\x1b[m\n", .{
            address,
            symbol_info.symbol_name,
            symbol_info.compile_unit_name,
        });
    }
}

const source_files = [_][]const u8{
    "arch/x86_64/apic.zig",
    "arch/x86_64/cpu.zig",
    "arch/x86_64/gdt.zig",
    "arch/x86_64/idt.zig",
    "arch/x86_64/mem.zig",
    "arch/x86_64/x86_64.zig",
    "arch/x86_64.zig",
    "fs/initramfs.zig",
    "fs/tmpfs.zig",
    "fs/zero.zig",
    "lib/lock.zig",
    "lib/term.zig",
    "lib/tree.zig",
    "acpi.zig",
    "arch.zig",
    "debug.zig",
    "elf.zig",
    "event.zig",
    "lib.zig",
    "main.zig",
    "pmm.zig",
    "ps2.zig",
    "rand.zig",
    "sched.zig",
    "serial.zig",
    "smp.zig",
    "time.zig",
    "TTY.zig",
    "vfs.zig",
    "vmm.zig",
};

// TODO: get source files from filesystem instead + zig std lib files
fn printLineFromFile(writer: anytype, line_info: std.debug.LineInfo) !void {
    var contents: []const u8 = undefined;

    inline for (source_files) |src_path| {
        if (std.mem.endsWith(u8, line_info.file_name, src_path)) {
            contents = @embedFile(src_path);
            break;
        }
    } else return error.FileNotFound;

    var line: usize = 1;
    for (contents) |byte| {
        if (line == line_info.line) {
            try writer.writeByte(byte);
            if (byte == '\n') return;
        }
        if (byte == '\n') {
            line += 1;
        }
    }

    return error.EndOfFile;

    // var f = try fs.openFile(line_info.file_name);
    // defer f.close();

    // var buf: [std.mem.page_size]u8 = undefined;
    // var line: usize = 1;
    // while (true) {
    //     const amt_read = try f.read(buf[0..]);
    //     const slice = buf[0..amt_read];

    //     for (slice) |byte| {
    //         if (line == line_info.line) {
    //             try writer.writeByte(byte);
    //             if (byte == '\n') return;
    //         }
    //         if (byte == '\n') {
    //             line += 1;
    //         }
    //     }

    //     if (amt_read < buf.len) return error.EndOfFile;
    // }
}

fn initDebugInfo() !void {
    errdefer debug_info = null;
    const kernel_file = root.kernel_file_request.response.?.kernel_file;

    debug_info = .{
        .endian = .little,
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

fn getSectionSlice(elf: [*]const u8, section_name: []const u8) ![]const u8 {
    const sh_strndx = std.mem.readInt(u16, elf[62 .. 62 + 2], .little);
    const sh_num = std.mem.readInt(u16, elf[60 .. 60 + 2], .little);

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

fn getShdr(elf: [*]const u8, idx: u16) []const u8 {
    const sh_offset = std.mem.readInt(u64, elf[40 .. 40 + 8], .little);
    const sh_entsize = std.mem.readInt(u16, elf[58 .. 58 + 2], .little);
    const off = sh_offset + sh_entsize * idx;

    return elf[off .. off + sh_entsize];
}

fn getSectionData(elf: [*]const u8, shdr: []const u8) []const u8 {
    const offset = std.mem.readInt(u64, shdr[24..][0..8], .little);
    const size = std.mem.readInt(u64, shdr[32..][0..8], .little);

    return elf[offset .. offset + size];
}

fn getSectionName(names: []const u8, shdr: []const u8) ?[]const u8 {
    const offset = std.mem.readInt(u32, shdr[0..][0..4], .little);
    const len = std.mem.indexOfScalar(u8, names[offset..], 0) orelse return null;

    return names[offset .. offset + len];
}
