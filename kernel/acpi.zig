const std = @import("std");
const root = @import("root");
const vmm = @import("vmm.zig");
const apic = @import("apic.zig");
const log = std.log.scoped(.acpi);
const readIntNative = std.mem.readIntNative;

/// System Description Table
const SDT = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [6]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,

    pub inline fn data(self: *const @This()) []const u8 {
        const ptr: [*]const u8 = @ptrCast(@alignCast(self));
        return ptr[0..self.length][@sizeOf(SDT)..];
    }
};

/// Root System Description Pointer
const RSDP = extern struct {
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_addr: u32,
    length: u32,
    xsdt_addr: u64,
    extended_checksum: u8,
    reserved: [3]u8,

    inline fn useXSDT(self: RSDP) bool {
        return self.revision >= 2 and self.xsdt_addr != 0;
    }
};

pub fn init() void {
    const rsdp: *RSDP = @ptrCast(@alignCast(root.rsdp_request.response.?.address));

    log.info("revision: {}", .{rsdp.revision});
    log.info("uses XSDT: {}", .{rsdp.useXSDT()});

    if (rsdp.useXSDT()) {
        parse(u64, rsdp.xsdt_addr);
    } else {
        parse(u32, @intCast(rsdp.rsdt_addr));
    }
}

fn parse(comptime T: type, addr: u64) void {
    const rsdt: *SDT = @ptrFromInt(addr + vmm.higher_half);

    var sum: u8 = 0;
    for (0..rsdt.length) |i| {
        sum +%= @as([*]u8, @ptrCast(rsdt))[i];
    }
    if (sum != 0) {
        std.debug.panic("RSDT is invalid: sum = {}", .{sum});
    }

    log.info("RSDT is at 0x{x}", .{@intFromPtr(rsdt)});

    const entries = std.mem.bytesAsSlice(T, rsdt.data());
    for (entries) |entry| {
        const sdt: *const SDT = @ptrFromInt(entry + vmm.higher_half);

        switch (readIntNative(u32, &sdt.signature)) {
            readIntNative(u32, "APIC") => handleMADT(sdt),
            else => log.warn("unhandled ACPI table: {s}", .{sdt.signature}),
        }
    }
}

fn handleMADT(madt: *const SDT) void {
    var data = madt.data()[8..]; // discard madt header

    while (data.len > 2) {
        const kind = data[0];
        const size = data[1];

        if (size >= data.len) break;

        const entry = data[2..size];
        switch (kind) {
            0 => log.warn("unhandled LAPIC: {any}", .{entry}),
            1 => apic.io_apics.append(@ptrCast(entry)) catch unreachable,
            2 => apic.isos.append(@ptrCast(entry)) catch unreachable,
            3 => log.warn("unhandled IO/APIC NMI source: {any}", .{entry}),
            4 => log.warn("unhandled LAPIC NMI: {any}", .{entry}),
            5 => log.warn("unhandled LAPIC Address Override: {any}", .{entry}),
            9 => log.warn("unhandled x2LAPIC: {any}", .{entry}),
            else => unreachable,
        }

        data = data[@max(2, size)..];
    }
}
