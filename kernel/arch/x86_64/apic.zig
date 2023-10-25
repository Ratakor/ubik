const std = @import("std");
const root = @import("root");
const x86 = @import("x86_64.zig");
const vmm = root.vmm;
const smp = root.smp;
const pit = root.time;
const SpinLock = root.SpinLock;

const Register = enum(u64) {
    lapic_id = 0x020,
    eoi = 0x0b0, // end of interrupt
    spurious = 0x0f0,
    cmci = 0x2f0, // LVT corrected machine check interrupt
    icr0 = 0x300, // interrupt command register
    icr1 = 0x310,
    lvt_timer = 0x320,
    timer_initial_count = 0x380,
    timer_current_count = 0x390,
    timer_divide = 0x3e0,
};

/// Input/Output Advanced Programmable Interrupt Controller
const IOAPIC = extern struct {
    apic_id: u8 align(1),
    reserved: u8 align(1),
    addr: u32 align(1),
    base_gsi: u32 align(1),

    const Self = @This();

    fn read(self: Self, reg: u32) u32 {
        const base: [*]volatile u32 = @ptrFromInt(self.addr + vmm.hhdm_offset);
        base[0] = reg;
        return base[4];
    }

    fn write(self: Self, reg: u32, value: u32) void {
        const base: [*]volatile u32 = @ptrFromInt(self.addr + vmm.hhdm_offset);
        base[0] = reg;
        base[4] = value;
    }

    fn gsiCount(self: Self) u32 {
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

pub var lapic_base: u32 = undefined; // set in acpi.zig with handleMADT()

pub var io_apics: std.ArrayListUnmanaged(*const IOAPIC) = .{};
pub var isos: std.ArrayListUnmanaged(*const ISO) = .{};

var init_lock: SpinLock = .{};

pub fn init() void {
    init_lock.lock();
    defer init_lock.unlock();

    timerCalibrate();

    // configure spurious IRQ
    writeRegister(.spurious, readRegister(.spurious) | (1 << 8) | 0xff);
}

pub inline fn eoi() void {
    writeRegister(.eoi, 0);
}

pub fn timerOneShot(microseconds: u64, vector: u8) void {
    const old_state = x86.toggleInterrupts(false);
    defer _ = x86.toggleInterrupts(old_state);

    timerStop();

    const ticks = microseconds * (smp.thisCpu().lapic_freq / 1_000_000);

    writeRegister(.lvt_timer, vector);
    writeRegister(.timer_divide, 0);
    writeRegister(.timer_initial_count, @truncate(ticks));
}

pub fn timerStop() void {
    writeRegister(.timer_initial_count, 0);
    writeRegister(.lvt_timer, 1 << 16);
}

pub fn sendIPI(lapic_id: u32, vector: u32) void {
    writeRegister(.icr1, lapic_id << 24);
    writeRegister(.icr0, vector | (1 << 14)); // clear init level
}

// TODO
pub fn timerCalibrate() void {
    timerStop();

    // init PIT
    writeRegister(.lvt_timer, (1 << 16) | 0xff); // vector 0xff, masked
    writeRegister(.timer_divide, 0);

    pit.setReloadValue(0xffff); // reset PIT

    const samples: u64 = 0xfffff;
    const initial_tick = pit.getCurrentCount();

    writeRegister(.timer_initial_count, @truncate(samples));
    while (readRegister(.timer_current_count) != 0) {}

    const final_tick = pit.getCurrentCount();

    const total_ticks: u64 = initial_tick - final_tick;
    smp.thisCpu().lapic_freq = (samples / total_ticks) * pit.dividend;

    timerStop();
}

fn readRegister(register: Register) u32 {
    const reg = @intFromEnum(register);
    return @as(*volatile u32, @ptrFromInt(lapic_base + vmm.hhdm_offset + reg)).*;
}

fn writeRegister(register: Register, val: u32) void {
    const reg = @intFromEnum(register);
    const ptr: *volatile u32 = @ptrFromInt(lapic_base + vmm.hhdm_offset + reg);
    ptr.* = val;
}

fn setGSIRedirect(lapic_id: u32, vector: u8, gsi: u8, flags: u16) void {
    const io_apic = for (io_apics.items) |io_apic| {
        if (gsi >= io_apic.base_gsi and gsi < io_apic.base_gsi + io_apic.gsiCount()) {
            break io_apic;
        }
    } else {
        std.debug.panic("Could not find an IOAPIC for GSI {}", .{gsi});
    };

    var redirect: u64 = vector;
    if ((flags & (1 << 1)) != 0) {
        redirect |= (1 << 13);
    }

    if ((flags & (1 << 3)) != 0) {
        redirect |= (1 << 15);
    }

    redirect |= @as(u64, @intCast(lapic_id)) << 56;

    const io_redirect_table = 0x10 + (gsi - io_apic.base_gsi) * 2;
    io_apic.write(io_redirect_table, @truncate(redirect));
    io_apic.write(io_redirect_table + 1, @truncate(redirect >> 32));
}

pub fn setIRQRedirect(lapic_id: u32, vector: u8, irq: u8) void {
    for (isos.items) |iso| {
        if (iso.irq_source == irq) {
            setGSIRedirect(lapic_id, vector, @intCast(iso.gsi), iso.flags);
            return;
        }
    }

    setGSIRedirect(lapic_id, vector, irq, 0);
}