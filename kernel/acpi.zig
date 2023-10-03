const std = @import("std");
const root = @import("root");
const vmm = @import("vmm.zig");
const apic = @import("apic.zig");
const log = std.log.scoped(.acpi);

const readIntNative = std.mem.readIntNative;

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

    switch (rsdp.revision) {
        0 => parse(u32, @intCast(rsdp.rsdt_addr)),
        2 => parse(u64, rsdp.xsdt_addr),
        else => unreachable,
    }
}

fn parse(comptime T: type, addr: u64) void {
    const sdt: *SDT = @ptrFromInt(addr + vmm.higher_half);
    const entries = std.mem.bytesAsSlice(T, sdt.data());

    log.info("RSDT is at 0x{x}", .{@intFromPtr(sdt)});

    for (entries) |entry| {
        handleTable(@ptrFromInt(entry + vmm.higher_half));
    }
}

fn handleTable(sdt: *const SDT) void {
    switch (readIntNative(u32, sdt.signature[0..4])) {
        readIntNative(u32, "APIC") => {
            var data = sdt.data()[8..];

            while (data.len >= 2) {
                const kind = data[0];
                const size = data[1];

                if (size >= data.len) break;

                const record_data = data[2..size];
                switch (kind) {
                    0 => {}, // TODO: find about this
                    1 => apic.handleIOAPIC(
                        record_data[0],
                        readIntNative(u32, record_data[2..6]),
                        readIntNative(u32, record_data[6..10]),
                    ),
                    2 => apic.handleIOAPICISO(
                        record_data[0],
                        record_data[1],
                        readIntNative(u32, record_data[2..6]),
                        readIntNative(u16, record_data[6..8]),
                    ),
                    3 => log.debug("unhandled IO/APIC NMI source: {any}", .{record_data}),
                    4 => log.debug("unhandled LAPIC NMI: {any}", .{record_data}),
                    5 => log.debug("unhandled LAPIC Address Override: {any}", .{record_data}),
                    9 => log.debug("unhandled x2LAPIC: {any}", .{record_data}),
                    else => log.warn("unknown MADT record 0x{x}: {any}", .{ kind, record_data }),
                }

                data = data[@max(2, size)..];
            }
        },
        // TODO:
        // readIntNative(u32, "FACP") => {
        //     const fadt_flags = @as([*]const u32, @ptrCast(sdt))[28];
        //     if (fadt_flags & (1 << 20) != 0) {
        //         @panic("Ubik does not support HW reduced ACPI systems");
        //     }
        // },
        else => log.debug("unhandled ACPI table: {s}", .{sdt.signature}),
    }
}
