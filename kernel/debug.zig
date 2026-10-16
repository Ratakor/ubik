const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const target = @import("arch.zig");
const arch = root.arch;
const serial = @import("serial.zig");
const smp = root.smp;
const time = root.time;
const SpinLock = root.SpinLock;
// Zig 0.16's std.debug.StackIterator is private and its self-unwinder needs
// hosted I/O. The kernel keeps frame pointers and resolves frames with DWARF.
const StackIterator = struct {
    frame_address: usize,
    first_address: ?usize,
    remaining: usize = 1024,

    fn init(first_address: usize, frame_address: usize) StackIterator {
        return .{ .first_address = first_address, .frame_address = frame_address };
    }

    fn next(self: *StackIterator) ?usize {
        comptime std.debug.assert(builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .riscv64);
        while (self.frame_address != 0 and self.remaining != 0) {
            self.remaining -= 1;
            if (!std.mem.isAligned(self.frame_address, @alignOf(usize))) return null;
            // RISC-V's frame pointer is above the saved FP/RA pair; x86-64
            // and AArch64 point directly at the saved frame pointer.
            const frame_base = if (builtin.cpu.arch == .riscv64)
                std.math.sub(usize, self.frame_address, 2 * @sizeOf(usize)) catch return null
            else
                self.frame_address;
            if (frame_base == 0) return null;
            const frame: *const [2]usize = @ptrFromInt(frame_base);
            const previous = frame[0];
            const address = frame[1];
            if (previous != 0 and previous <= self.frame_address) return null;
            self.frame_address = previous;
            if (address <= 1) return null;
            if (self.first_address) |first| {
                if (address != first) continue;
                self.first_address = null;
            }
            return address;
        }
        return null;
    }
};

var log_lock: SpinLock = .{};
var panic_lock: SpinLock = .{};

var fba_buffer: [32 * 1024 * 1024]u8 = undefined; // 32MiB
var debug_fba = std.heap.FixedBufferAllocator.init(&fba_buffer);
const debug_allocator = debug_fba.allocator();
var debug_info: ?std.debug.Dwarf = null;

// Logging can run while the heap allocator is locked, including its own logs.
// Keep the message buffer bounded so logging never allocates from that heap.
var dmesg_buffer: [1024 * 1024]u8 = undefined;
var dmesg_writer: std.Io.Writer = .fixed(&dmesg_buffer);

pub fn init() void {
    dmesg_writer = .fixed(&dmesg_buffer);
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime switch (level) {
        .err => "\x1b[31merror\x1b[m",
        .warn => "\x1b[33mwarning\x1b[m",
        .info => "\x1b[32minfo\x1b[m",
        .debug => "\x1b[36mdebug\x1b[m",
    };
    const scope_prefix = if (scope == .default) ": " else "@" ++ @tagName(scope) ++ ": ";
    const fmt = level_txt ++ scope_prefix ++ format ++ "\n";

    log_lock.lock();
    defer log_lock.unlock();

    if (comptime scope != .DebugAllocator) {
        dmesg_writer.print("[{d: >5}.{d:0>6}] ", .{
            @as(usize, @intCast(time.monotonic.sec)),
            @as(usize, @intCast(time.monotonic.nsec)) / std.time.ns_per_ms,
        }) catch {};
        dmesg_writer.print(fmt, args) catch {};
    }

    if (comptime builtin.mode == .Debug) {
        serial.print("[{d: >5}.{d:0>6}] ", .{
            @as(usize, @intCast(time.monotonic.sec)),
            @as(usize, @intCast(time.monotonic.nsec)) / std.time.ns_per_ms,
        });
        serial.print(fmt, args);
    }
}

pub fn panic(msg: []const u8, ret_addr: ?usize) noreturn {
    @branchHint(.cold);

    arch.disableInterrupts();

    if (!panic_lock.tryLock()) {
        arch.halt();
    }

    smp.stopAll();

    const fmt = "\x1b[m\x1b[31m\nKernel panic:\x1b[m {s}\n";
    const stack_iter = StackIterator.init(ret_addr orelse @returnAddress(), @frameAddress());

    dmesg_writer.print(fmt, .{msg}) catch {};
    printStackIterator(&dmesg_writer, stack_iter);

    serial.print(fmt, .{msg});
    printStackIterator(&serial.writer, stack_iter);

    if (root.tty0) |tty| {
        const writer = tty.writer();
        writer.print(fmt, .{msg}) catch {};
        printStackIterator(writer, stack_iter);
        root.term.hideCursor(writer) catch {};
    }

    arch.halt();
}

fn printStackIterator(writer: *std.Io.Writer, stack_iter: StackIterator) void {
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

fn printSymbolInfo(writer: *std.Io.Writer, address: u64) !void {
    const symbol: std.debug.Symbol = if (debug_info.?.findCompileUnit(target.endian, address)) |compile_unit| .{
        .name = debug_info.?.getSymbolName(address) orelse "???",
        .compile_unit_name = compile_unit.die.getAttrString(
            &debug_info.?,
            target.endian,
            std.dwarf.AT.name,
            debug_info.?.section(.debug_str),
            compile_unit,
        ) catch "???",
        .source_location = debug_info.?.getLineNumberInfo(debug_allocator, debug_allocator, target.endian, compile_unit, address) catch |err| switch (err) {
            error.MissingDebugInfo, error.InvalidDebugInfo => null,
            else => return err,
        },
    } else |err| switch (err) {
        error.MissingDebugInfo, error.InvalidDebugInfo => .unknown,
        else => return err,
    };
    defer if (symbol.source_location) |sl| debug_allocator.free(sl.file_name);

    if (symbol.source_location) |sl| {
        try writer.print("\x1b[1m{s}:{d}:{d}\x1b[m: \x1b[2m0x{x:0>16} in {s} ({s})\x1b[m\n", .{
            sl.file_name,
            sl.line,
            sl.column,
            address,
            symbol.name orelse "???",
            symbol.compile_unit_name orelse "???",
        });

        if (printLineFromFile(writer, &sl)) {
            if (sl.column > 0) {
                try writer.splatByteAll(' ', sl.column - 1);
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
            symbol.name orelse "???",
            symbol.compile_unit_name orelse "???",
        });
    }
}

const source_files = [_][]const u8{
    "arch/x86_64/apic.zig",
    "arch/x86_64/cpu.zig",
    "arch/x86_64/gdt.zig",
    "arch/x86_64/idt.zig",
    "arch/x86_64/mem.zig",

    "arch/x86_64.zig",
    "fs/initramfs.zig",
    "fs/tmpfs.zig",
    "fs/zero.zig",
    "lib/lock.zig",
    "lib/term.zig",
    "mm/HeapAllocator.zig",
    "mm/PageAllocator.zig",
    "mm/pmm.zig",
    "mm/vmm.zig",
    "acpi.zig",
    "arch.zig",
    "debug.zig",
    "elf.zig",
    "event.zig",
    "lib.zig",
    "main.zig",
    "ps2.zig",
    "rand.zig",
    "sched.zig",
    "serial.zig",
    "smp.zig",
    "time.zig",
    "TTY.zig",
    "vfs.zig",
};

// TODO: get source files from filesystem instead + zig std lib files
fn printLineFromFile(writer: *std.Io.Writer, source_location: *const std.debug.SourceLocation) !void {
    const content = inline for (source_files) |src_path| {
        if (std.mem.endsWith(u8, source_location.file_name, src_path)) {
            break @embedFile(src_path);
        }
    } else return error.FileNotFound;

    var line: usize = 1;
    for (content) |byte| {
        if (line == source_location.line) {
            try writer.writeByte(byte);
            if (byte == '\n') return;
        }
        if (byte == '\n') {
            line += 1;
        }
    }

    return error.EndOfFile;

    // var f = try fs.openFile(source_location.file_name);
    // defer f.close();

    // var buf: [std.mem.page_size]u8 = undefined;
    // var line: usize = 1;
    // while (true) {
    //     const amt_read = try f.read(buf[0..]);
    //     const slice = buf[0..amt_read];

    //     for (slice) |byte| {
    //         if (line == source_location.line) {
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

    debug_info = .{};
    // These slices borrow the bootloader's ELF image. Populate all available
    // sections, including DWARF 5 string/range tables, without requiring them.
    inline for (std.enums.values(std.debug.Dwarf.Section.Id)) |id| {
        const data = getSectionSlice(kernel_file.address, "." ++ @tagName(id)) catch |err| switch (err) {
            error.SectionNotFound => null,
            else => return err,
        };
        if (data) |bytes| {
            debug_info.?.sections[@intFromEnum(id)] = .{ .data = bytes, .owned = false };
        }
    }

    try debug_info.?.open(debug_allocator, target.endian);
}

fn getSectionSlice(elf: [*]const u8, section_name: []const u8) ![]const u8 {
    const sh_strndx = std.mem.readInt(u16, elf[62 .. 62 + 2], target.endian);
    const sh_num = std.mem.readInt(u16, elf[60 .. 60 + 2], target.endian);

    if (sh_strndx >= sh_num) {
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
    const sh_offset = std.mem.readInt(u64, elf[40 .. 40 + 8], target.endian);
    const sh_entsize = std.mem.readInt(u16, elf[58 .. 58 + 2], target.endian);
    const off = sh_offset + sh_entsize * idx;

    return elf[off .. off + sh_entsize];
}

fn getSectionData(elf: [*]const u8, shdr: []const u8) []const u8 {
    const offset = std.mem.readInt(u64, shdr[24..][0..8], target.endian);
    const size = std.mem.readInt(u64, shdr[32..][0..8], target.endian);

    return elf[offset .. offset + size];
}

fn getSectionName(names: []const u8, shdr: []const u8) ?[]const u8 {
    const offset = std.mem.readInt(u32, shdr[0..][0..4], target.endian);
    const len = std.mem.indexOfScalar(u8, names[offset..], 0) orelse return null;

    return names[offset .. offset + len];
}

test "frame iterator skips to requested address and stops at the sentinel" {
    const fp_offset: usize = if (builtin.cpu.arch == .riscv64) 2 * @sizeOf(usize) else 0;
    var frames: [3][2]usize = undefined;
    frames[0] = .{ @intFromPtr(&frames[1]) + fp_offset, 0x100 };
    frames[1] = .{ @intFromPtr(&frames[2]) + fp_offset, 0x200 };
    frames[2] = .{ 0, 0x300 };
    var iter = StackIterator.init(0x200, @intFromPtr(&frames[0]) + fp_offset);
    try std.testing.expectEqual(@as(?usize, 0x200), iter.next());
    try std.testing.expectEqual(@as(?usize, 0x300), iter.next());
    try std.testing.expectEqual(@as(?usize, null), iter.next());

    frames[0][0] = @intFromPtr(&frames[0]) + fp_offset;
    iter = StackIterator.init(0x100, @intFromPtr(&frames[0]) + fp_offset);
    try std.testing.expectEqual(@as(?usize, null), iter.next());
}

test "allocator verbosity does not consume the bounded kernel log" {
    init();
    defer init();
    log(.info, .DebugAllocator, "allocation", .{});
    try std.testing.expectEqual(@as(usize, 0), dmesg_writer.end);
    log(.info, .kernel_test, "kernel message", .{});
    try std.testing.expect(dmesg_writer.end != 0);
}

test "bounded logging does not grow when full" {
    init();
    defer init();
    try dmesg_writer.splatByteAll('x', dmesg_buffer.len);
    try std.testing.expectError(error.WriteFailed, dmesg_writer.writeByte('y'));
    try std.testing.expectEqual(dmesg_buffer.len, dmesg_writer.end);
}

test "DWARF symbol output retains the unknown-address fallback" {
    debug_info = .{};
    defer debug_info = null;
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try printSymbolInfo(&writer, 0x1234);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "0x0000000000001234 in ??? (???)") != null);
}
