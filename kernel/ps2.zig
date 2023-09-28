const idt = @import("idt.zig");
const serial = @import("serial.zig");

pub var keyboard_vector = undefined;

// TODO: handle keyboard inputs

// TODO: too complicated ?
pub fn init() void {
    // Disable primary and secondary PS/2 ports
    write(0x64, 0xad);
    write(0x64, 0xa7);

    var config = readConfig();
    // Enable keyboard interrupt and keyboard scancode translation
    config |= (1 << 0) | (1 << 6);
    // Enable mouse interrupt if any
    if ((config & (1 << 5)) != 0) {
        config |= (1 << 1);
    }
    writeConfig(config);

    // Enable keyboard port
    write(0x64, 0xae);
    // Enable mouse port if any
    if ((config & (1 << 5)) != 0) {
        write(0x64, 0xa8);
    }

    keyboard_vector = idt.allocateVector();
    // TODO
    // ioapic.setIRQRedirect(bsp_lapic_id, keyboard_vector, 1, true);
    serial.in(u8, 0x60);
}

pub fn read() u8 {
    while ((serial.in(u8, 0x64) & 1) == 0) {}
    return serial.in(u8, 0x60);
}

pub fn write(port: u16, value: u8) void {
    while ((serial.in(u8, 0x64) & 2) == 0) {}
    serial.out(u8, port, value);
}

fn readConfig() u8 {
    write(0x64, 0x20);
    return read();
}

fn writeConfig(value: u8) void {
    write(0x64, 0x60);
    write(0x60, value);
}
