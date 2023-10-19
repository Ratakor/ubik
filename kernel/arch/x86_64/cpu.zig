const std = @import("std");
const limine = @import("limine");
const root = @import("root");
const x86 = @import("x86_64.zig");
const gdt = @import("idt.zig");
const idt = @import("idt.zig");
const log = std.log.scoped(.cpu);

const PAT = packed struct {
    // zig fmt: off
    pat0: Flags, reserved0: u5,
    pat1: Flags, reserved1: u5,
    pat2: Flags, reserved2: u5,
    pat3: Flags, reserved3: u5,
    pat4: Flags, reserved4: u5,
    pat5: Flags, reserved5: u5,
    pat6: Flags, reserved6: u5,
    pat7: Flags, reserved7: u5,
    // zig fmt: on

    const Flags = enum(u3) {
        uncacheable = 0,
        write_combining = 1,
        write_through = 4,
        write_protect = 5,
        write_back = 6,
        uncached = 7,
    };

    comptime {
        std.debug.assert(@sizeOf(PAT) == @sizeOf(u64));
        std.debug.assert(@bitSizeOf(PAT) == @bitSizeOf(u64));
    }
};

/// https://en.wikipedia.org/wiki/CPUID#EAX=1:_Processor_Info_and_Feature_Bits
const Feature = enum(u64) {
    // ecx
    sse3 = 1 << 0,
    pclmul = 1 << 1,
    dtes64 = 1 << 2,
    monitor = 1 << 3,
    ds_cpl = 1 << 4,
    vmx = 1 << 5,
    smx = 1 << 6,
    est = 1 << 7,
    tm2 = 1 << 8,
    ssse3 = 1 << 9,
    cxd = 1 << 10,
    sdbg = 1 << 11,
    fma = 1 << 12,
    cx16 = 1 << 13,
    xtpr = 1 << 14,
    pdcm = 1 << 15,
    pcid = 1 << 17,
    dca = 1 << 18,
    sse4_1 = 1 << 19,
    sse4_2 = 1 << 20,
    x2apic = 1 << 21,
    movbe = 1 << 22,
    popcnt = 1 << 23,
    tsc_deadline = 1 << 24,
    aes = 1 << 25,
    xsave = 1 << 26,
    osxsave = 1 << 27,
    avx = 1 << 28,
    f16c = 1 << 29,
    rdrand = 1 << 30,

    // edx
    fpu = 1 << 32,
    vme = 1 << 33,
    de = 1 << 34,
    pse = 1 << 35,
    tsc = 1 << 36,
    msr = 1 << 37,
    pae = 1 << 38,
    mce = 1 << 39,
    cx8 = 1 << 40,
    apic = 1 << 41,
    sep = 1 << 43,
    mtrr = 1 << 44,
    pge = 1 << 45,
    mca = 1 << 46,
    cmov = 1 << 47,
    pat = 1 << 48,
    pse36 = 1 << 49,
    psn = 1 << 50,
    clflush = 1 << 51,
    ds = 1 << 53,
    acpi = 1 << 54,
    mmx = 1 << 55,
    fxsr = 1 << 56,
    sse = 1 << 57,
    sse2 = 1 << 58,
    ss = 1 << 59,
    htt = 1 << 60,
    tm = 1 << 61,
    ia64 = 1 << 62,
    pbe = 1 << 63,
};

/// https://en.wikipedia.org/wiki/Control_register#CR0
const CR0 = enum(u64) {
    pe = 1 << 0,
    mp = 1 << 1,
    em = 1 << 2,
    ts = 1 << 3,
    et = 1 << 4,
    ne = 1 << 5,
    wp = 1 << 16,
    am = 1 << 18,
    nw = 1 << 29,
    cd = 1 << 30,
    pg = 1 << 31,
};

/// https://en.wikipedia.org/wiki/Control_register#CR4
const CR4 = enum(u64) {
    vme = 1 << 0,
    pvi = 1 << 1,
    tsd = 1 << 2,
    de = 1 << 3,
    pse = 1 << 4,
    pae = 1 << 5,
    mce = 1 << 6,
    pge = 1 << 7,
    pce = 1 << 8,
    osfxsr = 1 << 9,
    osxmmexcpt = 1 << 10,
    umip = 1 << 11,
    la57 = 1 << 12,
    vmxe = 1 << 13,
    smxe = 1 << 14,
    fsgsbase = 1 << 16,
    pcide = 1 << 17,
    osxsave = 1 << 18,
    kl = 1 << 19,
    smep = 1 << 20,
    smap = 1 << 21,
    pke = 1 << 22,
    cet = 1 << 23,
    pks = 1 << 24,
    uintr = 1 << 25,
};

/// https://en.wikipedia.org/wiki/Control_register#XCR0_and_XSS
const XCR0 = enum(u64) {
    x87 = 1 << 0,
    sse = 1 << 1,
    avx = 1 << 2,
    bndreg = 1 << 3,
    bndcsr = 1 << 4,
    opmask = 1 << 5,
    zmm_hi256 = 1 << 6,
    hi16_zmm = 1 << 7,
    pkru = 1 << 9,
};

pub var use_xsave = false;
pub var fpu_storage_size: usize = 512; // 512 = fxsave storage

inline fn hasFeature(features: u64, feat: Feature) bool {
    return features & @intFromEnum(feat) != 0;
}

pub fn initFeatures(bsp: bool) void {
    const regs = x86.cpuid(1, 0);
    const features: u64 = @as(u64, regs.edx) << 32 | regs.ecx;

    // enable SSE/SSE2
    var cr0: u64 = x86.readRegister("cr0");
    cr0 &= ~@intFromEnum(CR0.em);
    cr0 |= @intFromEnum(CR0.mp);
    x86.writeRegister("cr0", cr0);

    var cr4: u64 = x86.readRegister("cr4");
    cr4 |= @intFromEnum(CR4.osfxsr);
    cr4 |= @intFromEnum(CR4.osxmmexcpt);
    x86.writeRegister("cr4", cr4);

    // init PAT
    var pat: PAT = @bitCast(x86.rdmsr(0x277));
    pat.pat4 = PAT.Flags.write_protect;
    pat.pat5 = PAT.Flags.write_combining;
    x86.wrmsr(0x277, @bitCast(pat));

    if (hasFeature(features, .xsave)) {
        if (bsp) log.info("xsave is supported", .{});
        use_xsave = true;

        cr4 = x86.readRegister("cr4");
        cr4 |= @intFromEnum(CR4.osxsave);
        x86.writeRegister("cr4", cr4);

        var xcr0: u64 = 0;
        xcr0 |= @intFromEnum(XCR0.x87);
        xcr0 |= @intFromEnum(XCR0.sse);

        if (hasFeature(features, .avx)) {
            if (bsp) log.info("saving avx state using xsave", .{});
            xcr0 |= @intFromEnum(XCR0.avx);
        }

        if (x86.cpuid(7, 0).ebx & @as(u64, 1 << 16) != 0) {
            if (bsp) log.info("saving avx512 state using xsave", .{});
            xcr0 |= @intFromEnum(XCR0.opmask);
            xcr0 |= @intFromEnum(XCR0.zmm_hi256);
            xcr0 |= @intFromEnum(XCR0.hi16_zmm);
        }

        x86.wrxcr(0, xcr0);

        fpu_storage_size = x86.cpuid(0xd, 0).ecx;
    }

    // TODO
    // asm volatile ("fninit");
}

pub inline fn fpuSave(ctx: u64) void {
    if (use_xsave) x86.xsave(ctx) else x86.fxsave(ctx);
}

pub inline fn fpuRestore(ctx: u64) void {
    if (use_xsave) x86.xrstor(ctx) else x86.fxrstor(ctx);
}
