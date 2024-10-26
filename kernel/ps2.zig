const std = @import("std");
const root = @import("root");
const arch = @import("arch.zig");
const idt = arch.idt;
const apic = arch.apic;
const smp = @import("smp.zig");

pub var keyboard_vector: u8 = undefined;

pub fn init() void {
    // disable primary and secondary PS/2 ports
    write(0x64, 0xad);
    write(0x64, 0xa7);

    var config = readConfig();
    // enable keyboard interrupt and keyboard scancode translation
    config |= (1 << 0) | (1 << 6);
    // enable mouse interrupt if any
    if ((config & (1 << 5)) != 0) {
        config |= (1 << 1);
    }
    writeConfig(config);

    // enable keyboard port
    write(0x64, 0xae);
    // enable mouse port if any
    if ((config & (1 << 5)) != 0) {
        write(0x64, 0xa8);
    }

    keyboard_vector = idt.allocVector();
    apic.setIRQRedirect(smp.bsp_lapic_id, keyboard_vector, 1, true);

    _ = arch.in(u8, 0x60);
}

pub fn read() u8 {
    // while ((arch.in(u8, 0x64) & 1) == 0) {}
    return arch.in(u8, 0x60);
}

fn write(port: u16, value: u8) void {
    // while ((arch.in(u8, 0x64) & 2) == 0) {}
    arch.out(u8, port, value);
}

fn readConfig() u8 {
    write(0x64, 0x20);
    return read();
}

fn writeConfig(value: u8) void {
    write(0x64, 0x60);
    write(0x60, value);
}
