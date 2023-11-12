const std = @import("std");
const root = @import("root");
const x86 = @import("x86_64.zig");
const pit = @import("pit.zig");
const vmm = root.vmm;
const smp = root.smp;
const SpinLock = root.SpinLock;

/// Local Advanced Programmable Interrupt Controller
const LAPIC = struct {
    // intel manual volume 3A page 11-6 (396)
    const Register = enum(u64) {
        lapic_id = 0x020,
        eoi = 0x0b0, // end of interrupt
        spurious = 0x0f0,
        cmci = 0x2f0, // LVT corrected machine check interrupt
        icr_low = 0x300,
        icr_high = 0x310,
        lvt_timer = 0x320,
        lvt_thermal = 0x330, // LVT thermal sensor
        lvt_perf = 0x340, // LVT performance monitoring counters
        timer_initial_count = 0x380,
        timer_current_count = 0x390,
        timer_divide = 0x3e0,
    };

    fn read(register: Register) u32 {
        const reg = @intFromEnum(register);
        return @as(*volatile u32, @ptrFromInt(lapic_base + reg)).*;
    }

    fn write(register: Register, val: u32) void {
        const reg = @intFromEnum(register);
        const addr: *volatile u32 = @ptrFromInt(lapic_base + reg);
        addr.* = val;
    }
};

/// Input/Output Advanced Programmable Interrupt Controller
const IOAPIC = extern struct {
    apic_id: u8 align(1),
    reserved: u8 align(1),
    addr: u32 align(1),
    base_gsi: u32 align(1),

    const Redirect = packed struct(u64) {
        vector: u8,
        delivery_mode: u3 = 0,
        destination_mode: u1 = 0,
        delivery_status: u1 = 0,
        pin_polarity: u1,
        remote_irr: u1 = 0,
        trigger_mode: u1,
        mask: u1,
        reserved: u39 = 0,
        destination: u8,

        inline fn low(self: Redirect) u32 {
            return @truncate(@as(u64, @bitCast(self)));
        }

        inline fn high(self: Redirect) u32 {
            return @truncate(@as(u64, @bitCast(self)) >> 32);
        }
    };

    fn read(self: IOAPIC, reg: u32) u32 {
        const base: [*]volatile u32 = @ptrFromInt(self.addr + vmm.hhdm_offset);
        base[0] = reg;
        return base[4];
    }

    fn write(self: IOAPIC, reg: u32, value: u32) void {
        const base: [*]volatile u32 = @ptrFromInt(self.addr + vmm.hhdm_offset);
        base[0] = reg;
        base[4] = value;
    }

    fn gsiCount(self: IOAPIC) u32 {
        return (self.read(1) & 0xff0000) >> 16;
    }
};

/// Interrupt Source Override
const ISO = extern struct {
    bus_source: u8 align(1),
    irq_source: u8 align(1),
    gsi: u32 align(1),
    flags: u16 align(1),
};

// look intel manual volume 3A page 11-19 (409) for details about each field
/// Interrupt Command Register (bits 0-31)
const ICRLow = packed struct(u32) {
    vector: u8,
    delivery_mode: u3 = 0b000,
    destination_mode: u1 = 0b0,
    delivery_status: u1 = 0, // read-only
    reserved0: u1 = 0,
    level: u1 = 0b1,
    trigger_mode: u1 = 0b0,
    reserved1: u2 = 0,
    destination_shorthand: DestinationShorthand = .no_shorthand,
    reserved2: u12 = 0,

    const DestinationShorthand = enum(u2) {
        no_shorthand = 0b00,
        self = 0b01,
        all_including_self = 0b10,
        all_excluding_self = 0b11,
    };
};

pub var lapic_base: u64 = undefined; // set in acpi.zig with handleMADT()
pub var io_apics: std.ArrayListUnmanaged(*const IOAPIC) = .{};
pub var isos: std.ArrayListUnmanaged(*const ISO) = .{};

var init_lock: SpinLock = .{};

pub fn init() void {
    init_lock.lock();
    defer init_lock.unlock();

    timerCalibrate();

    // configure spurious IRQ
    LAPIC.write(.spurious, LAPIC.read(.spurious) | 0x1ff);
}

pub inline fn eoi() void {
    LAPIC.write(.eoi, 0);
}

pub fn timerOneShot(microseconds: u64, vector: u8) void {
    const old_state = x86.toggleInterrupts(false);
    defer _ = x86.toggleInterrupts(old_state);

    const ticks = microseconds * (smp.thisCpu().lapic_freq / 1_000_000);

    LAPIC.write(.lvt_timer, vector); // clear mask and set vector
    LAPIC.write(.timer_divide, 0);
    LAPIC.write(.timer_initial_count, @intCast(ticks));
}

pub fn timerStop() void {
    LAPIC.write(.timer_initial_count, 0); // stop timer
    LAPIC.write(.lvt_timer, 1 << 16); // mask vector
}

pub fn sendIPI(lapic_id: u32, icr_low: ICRLow) void {
    LAPIC.write(.icr_high, lapic_id << 24); // bits 32-55 of ICR are reserved
    LAPIC.write(.icr_low, @bitCast(icr_low));
}

fn timerCalibrate() void {
    timerStop();
    LAPIC.write(.timer_divide, 0);
    pit.setReloadValue(0xffff); // reset PIT

    const samples = 0xfffff;
    const initial_tick = pit.getCurrentCount();

    LAPIC.write(.timer_initial_count, samples);
    while (LAPIC.read(.timer_current_count) != 0) {}

    const final_tick = pit.getCurrentCount();

    const total_ticks: u64 = initial_tick - final_tick;
    smp.thisCpu().lapic_freq = (samples / total_ticks) * pit.dividend;

    timerStop();
}

fn setGSIRedirect(lapic_id: u32, vector: u8, gsi: u8, flags: u16, enable: bool) void {
    const io_apic = for (io_apics.items) |io_apic| {
        if (gsi >= io_apic.base_gsi and gsi < io_apic.base_gsi + io_apic.gsiCount()) {
            break io_apic;
        }
    } else {
        std.debug.panic("Could not find an IOAPIC for GSI {}", .{gsi});
    };

    const redirect: IOAPIC.Redirect = .{
        .vector = vector,
        .pin_polarity = @intFromBool(flags & (1 << 1) != 0),
        .trigger_mode = @intFromBool(flags & (1 << 3) != 0),
        .mask = @intFromBool(!enable),
        .destination = @intCast(lapic_id),
    };

    const io_redirect_table = 0x10 + (gsi - io_apic.base_gsi) * 2;
    io_apic.write(io_redirect_table, redirect.low());
    io_apic.write(io_redirect_table + 1, redirect.high());
}

pub fn setIRQRedirect(lapic_id: u32, vector: u8, irq: u8, enable: bool) void {
    for (isos.items) |iso| {
        if (iso.irq_source == irq) {
            setGSIRedirect(lapic_id, vector, @intCast(iso.gsi), iso.flags, enable);
            return;
        }
    }

    setGSIRedirect(lapic_id, vector, irq, 0, enable);
}
