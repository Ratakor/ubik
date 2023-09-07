const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fat = b.addExecutable(.{
        .name = "fat",
        .root_source_file = .{ .path = "fat.zig" },
        .target = target,
        .optimize = optimize,
    });
    fat.strip = b.option(bool, "strip", "Strip the binary") orelse switch (optimize) {
        .Debug, .ReleaseSafe => false,
        .ReleaseFast, .ReleaseSmall => true,
    };
    b.installArtifact(fat);

    const run_cmd = b.addRunArtifact(fat);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    } else {
        run_cmd.addArg("../../build/floppy.img");
        run_cmd.addArg("TEST    TXT");
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const clean_step = b.step("clean", "Delete all artifacts created by zig build");
    clean_step.dependOn(&b.addRemoveDirTree("zig-cache").step);
    clean_step.dependOn(&b.addRemoveDirTree("zig-out").step);
}
