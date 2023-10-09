const std = @import("std");
const root = @import("root");
const vmm = @import("vmm.zig");
const apic = @import("apic.zig");
const log = std.log.scoped(.acpi);
const readIntNative = std.mem.readIntNative;

/// System Description Table
const SDT = extern struct {
    signature: [4]u8 align(1),
    length: u32 align(1),
    revision: u8 align(1),
    checksum: u8 align(1),
    oem_id: [6]u8 align(1),
    oem_table_id: [8]u8 align(1),
    oem_revision: u32 align(1),
    creator_id: u32 align(1),
    creator_revision: u32 align(1),

    inline fn data(self: *const SDT) []const u8 {
        const ptr: [*]const u8 = @ptrCast(self);
        return ptr[0..self.length][@sizeOf(SDT)..];
    }

    fn validChecksum(self: *const SDT) void {
        const ptr: [*]const u8 = @ptrCast(self);
        var sum: u8 = 0;
        for (0..self.length) |i| {
            sum +%= ptr[i];
        }
        if (sum != 0) {
            std.debug.panic("SDT `{s}` is invalid: sum = {}", .{ self.signature, sum });
        }
    }
};

/// Root System Description Pointer
const RSDP = extern struct {
    signature: [8]u8 align(1),
    checksum: u8 align(1),
    oem_id: [6]u8 align(1),
    revision: u8 align(1),
    rsdt_addr: u32 align(1),

    length: u32 align(1),
    xsdt_addr: u64 align(1),
    extended_checksum: u8 align(1),
    reserved: [3]u8 align(1),

    inline fn useXSDT(self: RSDP) bool {
        return self.revision >= 2 and self.xsdt_addr != 0;
    }
};

/// Generic Address Structure
const GAS = extern struct {
    address_space: u8 align(1),
    bit_width: u8 align(1),
    bit_offset: u8 align(1),
    access_size: u8 align(1),
    address: u64 align(1),
};

/// Fixed ACPI Description Table
const FADT = extern struct {
    header: SDT align(1),
    firmware_ctrl: u32 align(1),
    dsdt: u32 align(1),
    reserved1: u8 align(1), // ACPI 1 only
    preferred_power_management_profile: u8 align(1),
    sci_interrupt: u16 align(1),
    smi_command_port: u32 align(1),
    acpi_enable: u8 align(1),
    acpi_disable: u8 align(1),
    s4bios_req: u8 align(1),
    pstate_control: u8 align(1),
    pm1a_event_block: u32 align(1),
    pm1b_event_block: u32 align(1),
    pm1a_control_block: u32 align(1),
    pm1b_control_block: u32 align(1),
    pm2_control_block: u32 align(1),
    pm_timer_block: u32 align(1),
    gpe0_block: u32 align(1),
    gpe1_block: u32 align(1),
    pm1_event_length: u8 align(1),
    pm1_control_length: u8 align(1),
    pm2_control_length: u8 align(1),
    pm_timer_length: u8 align(1),
    gpe0_length: u8 align(1),
    gpe1_length: u8 align(1),
    gpe1_base: u8 align(1),
    c_state_control: u8 align(1),
    worst_c2_latency: u16 align(1),
    worst_c3_latency: u16 align(1),
    flush_size: u16 align(1),
    flush_stride: u16 align(1),
    duty_offset: u8 align(1),
    duty_width: u8 align(1),
    day_alarm: u8 align(1),
    month_alarm: u8 align(1),
    century: u8 align(1),
    boot_architecture_flags: u16 align(1), // ACPI 2 only
    reserved2: u8 align(1),
    flags: u32 align(1),
    reset_reg: GAS align(1),
    reset_value: u8 align(1),
    reserved3: [3]u8 align(1),
    x_firmware_control: u64 align(1), // ACPI 2 only
    x_dsdt: u64 align(1), // ACPI 2 only
    x_pm1a_event_block: GAS align(1),
    x_pm1b_event_block: GAS align(1),
    x_pm1a_control_block: GAS align(1),
    x_pm1b_control_block: GAS align(1),
    x_pm2_control_block: GAS align(1),
    x_pm_timer_block: GAS align(1),
    x_gpe0_block: GAS align(1),
    x_gpe1_block: GAS align(1),
};

var fadt: *const FADT = undefined;

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
    const rsdt: *const SDT = @ptrFromInt(addr + vmm.hhdm_offset);
    rsdt.validChecksum();
    log.info("RSDT is at 0x{x}", .{@intFromPtr(rsdt)});

    const entries = std.mem.bytesAsSlice(T, rsdt.data());
    for (entries) |entry| {
        const sdt: *const SDT = @ptrFromInt(entry + vmm.hhdm_offset);
        sdt.validChecksum();

        switch (readIntNative(u32, &sdt.signature)) {
            readIntNative(u32, "APIC") => handleMADT(sdt),
            readIntNative(u32, "FACP") => handleFADT(sdt),
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

fn handleFADT(sdt: *const SDT) void {
    fadt = @ptrCast(sdt);
}
