const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    var target: std.zig.CrossTarget = .{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    };

    // Disable CPU features that require additional initialization
    // like MMX, SSE/2 and AVX. That requires us to enable the soft-float feature.
    const Feature = std.Target.x86.Feature;
    target.cpu_features_sub.addFeature(@intFromEnum(Feature.mmx));
    target.cpu_features_sub.addFeature(@intFromEnum(Feature.sse));
    target.cpu_features_sub.addFeature(@intFromEnum(Feature.sse2));
    target.cpu_features_sub.addFeature(@intFromEnum(Feature.avx));
    target.cpu_features_sub.addFeature(@intFromEnum(Feature.avx2));
    target.cpu_features_add.addFeature(@intFromEnum(Feature.soft_float));

    const limine = b.dependency("limine", .{});
    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_source_file = .{ .path = "kernel/kernel.zig" },
        .target = target,
        .optimize = optimize,
    });
    kernel.code_model = .kernel;
    kernel.addModule("limine", limine.module("limine"));
    kernel.setLinkerScriptPath(.{ .path = "kernel/linker.ld" });
    kernel.pie = true;
    kernel.strip = b.option(bool, "strip", "Strip the kernel") orelse switch (optimize) {
        .Debug, .ReleaseSafe => false,
        .ReleaseFast, .ReleaseSmall => true,
    };
    b.installArtifact(kernel);
}
