const std = @import("std");

fn concat(b: *std.Build, slices: []const []const u8) []u8 {
    return std.mem.concat(b.allocator, u8, slices) catch unreachable;
}

fn buildKernel(b: *std.Build) *std.Build.Step.Compile {
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
        .root_source_file = .{ .path = "kernel/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    kernel.code_model = .kernel;
    kernel.addModule("limine", limine.module("limine"));
    kernel.setLinkerScriptPath(.{
        .path = concat(b, &[_][]const u8{ "kernel/linker-", @tagName(target.cpu_arch.?), ".ld" }),
    });
    kernel.pie = true;
    kernel.strip = b.option(bool, "strip", "Strip the kernel") orelse switch (optimize) {
        .Debug, .ReleaseSafe => false,
        .ReleaseFast, .ReleaseSmall => true,
    };

    return kernel;
}

fn buildImage(b: *std.Build, image_name: []const u8) *std.Build.Step.Run {
    const image_dir = b.cache_root.join(b.allocator, &[_][]const u8{"image_root/"}) catch unreachable;

    const image_params = &[_][]const u8{
        "/bin/sh", "-c",
        concat(b, &[_][]const u8{
            "make -C limine && ",
            "mkdir -p ", image_dir, " && ",
            "cp zig-out/bin/kernel.elf limine.cfg limine/limine-bios.sys ",
                "limine/limine-bios-cd.bin limine/limine-uefi-cd.bin ",
                image_dir, " && ",
            "mkdir -p ", image_dir, "EFI/BOOT && ",
            "cp limine/BOOTX64.EFI ", image_dir, "EFI/BOOT/ && ",
            "cp limine/BOOTIA32.EFI ", image_dir, "EFI/BOOT/ && ",
            "xorriso -as mkisofs -b limine-bios-cd.bin ",
                "-no-emul-boot -boot-load-size 4 -boot-info-table ",
                "--efi-boot limine-uefi-cd.bin ",
                "-efi-boot-part --efi-boot-image --protective-msdos-label ",
                image_dir, " -o ", image_name, " && ",
            "./limine/limine bios-install ", image_name,
        })
    };

    return b.addSystemCommand(image_params);
}

pub fn build(b: *std.Build) void {
    const kernel = buildKernel(b);
    b.installArtifact(kernel);

    const arch = @tagName(kernel.target.cpu_arch.?);
    const image_name = concat(b, &[_][]const u8{ "ubik-", arch, ".iso" });

    const image_step = b.step("image", "Build the image");
    const image_cmd = buildImage(b, image_name);
    image_cmd.step.dependOn(b.getInstallStep());
    image_step.dependOn(&image_cmd.step);

    const run_step = b.step("run", "Run the image with qemu");
    const graphics = b.option(bool, "graphics", "Enable graphics on qemu") orelse true;
    const qemu_cmd = concat(b, &[_][]const u8{ "qemu-system-", arch });
    const qemu_params = [_][]const u8{
        "-no-reboot",
        "-serial", "mon:stdio",
        "-M", "q35",
        "-m", "1G",
        "-smp", "2",
        "-boot", "d",
        "-cdrom", image_name
    };
    const run_cmd = if (graphics)
        b.addSystemCommand(&[_][]const u8{ qemu_cmd, "-vga", "std" } ++ qemu_params)
    else
        b.addSystemCommand(&[_][]const u8{ qemu_cmd, "-nographic" } ++ qemu_params);
    run_cmd.step.dependOn(image_step);
    run_step.dependOn(&run_cmd.step);

    const fmt_step = b.step("fmt", "Format all source files");
    fmt_step.dependOn(&b.addFmt(.{ .paths = &[_][]const u8{"kernel"} }).step);

    const clean_step = b.step("clean", "Delete all artifacts created by zig build");
    clean_step.dependOn(&b.addRemoveDirTree("zig-cache").step);
    clean_step.dependOn(&b.addRemoveDirTree("zig-out").step);
    clean_step.dependOn(&b.addRemoveDirTree(image_name).step);
}
