const std = @import("std");
const limine = @import("limine");
const root = @import("root");
const arch = @import("arch.zig");
const idt = arch.idt;
const apic = arch.apic;
const sched = @import("sched.zig");
const CpuLocal = arch.cpu.CpuLocal;
const log = std.log.scoped(.smp);

pub var bsp_lapic_id: u32 = undefined; // bootstrap processor lapic id
pub var cpus: []CpuLocal = undefined;
var cpus_started: usize = 0;
pub var initialized = false;

pub fn init() void {
    const smp = root.smp_request.response.?;
    bsp_lapic_id = smp.bsp_lapic_id;
    cpus = root.allocator.alloc(CpuLocal, smp.cpu_count) catch unreachable;
    @memset(std.mem.sliceAsBytes(cpus), 0);
    log.info("{} processors detected", .{cpus.len});

    for (smp.cpus(), cpus, 0..) |cpu, *cpu_local, id| {
        cpu.extra_argument = @intFromPtr(cpu_local);
        cpu_local.id = id;
        if (arch.arch == .x86_64) {
            cpu_local.lapic_id = cpu.lapic_id;
        }

        if (cpu.lapic_id != bsp_lapic_id) {
            cpu.goto_address = initAp;
        } else {
            cpu_local.initCpu(true);
            log.info("bootstrap processor is online with id: {}", .{cpu_local.id});
            _ = @atomicRmw(usize, &cpus_started, .Add, 1, .release);
        }
    }

    while (cpus_started != cpus.len) {
        std.atomic.spinLoopHint();
    }

    initialized = true;
}

pub fn stopAll() void {
    if (cpus_started > 0) {
        apic.sendIPI(undefined, .{
            .vector = idt.panic_ipi_vector,
            .destination_shorthand = .all_excluding_self,
        });
    }
}

pub inline fn thisCpu() *CpuLocal {
    std.debug.assert(arch.interruptState() == false); // or cpu.scheduling_disabled
    // TODO: use rdmsr or rdgsbase?
    return @ptrFromInt(arch.readRegister("gs:0x0"));
}

fn initAp(smp_info: *limine.SmpInfo) callconv(.C) noreturn {
    const cpu_local: *CpuLocal = @ptrFromInt(smp_info.extra_argument);

    cpu_local.initCpu(false);
    log.info("processor {} is online", .{cpu_local.id});
    _ = @atomicRmw(usize, &cpus_started, .Add, 1, .release);

    arch.enableInterrupts();
    arch.halt();
}
