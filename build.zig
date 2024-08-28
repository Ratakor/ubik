const std = @import("std");

fn concat(b: *std.Build, slices: []const []const u8) []u8 {
    return std.mem.concat(b.allocator, u8, slices) catch unreachable;
}

fn buildKernel(b: *std.Build) *std.Build.Step.Compile {
    const optimize = b.standardOptimizeOption(.{});
    var query: std.Target.Query = .{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    };

    // Disable CPU features that require additional initialization
    // like MMX, SSE/2 and AVX. That requires us to enable the soft-float feature.
    const Feature = std.Target.x86.Feature;
    query.cpu_features_sub.addFeature(@intFromEnum(Feature.mmx));
    query.cpu_features_sub.addFeature(@intFromEnum(Feature.sse));
    query.cpu_features_sub.addFeature(@intFromEnum(Feature.sse2));
    query.cpu_features_sub.addFeature(@intFromEnum(Feature.avx));
    query.cpu_features_sub.addFeature(@intFromEnum(Feature.avx2));
    query.cpu_features_add.addFeature(@intFromEnum(Feature.soft_float));

    const target = b.resolveTargetQuery(query);
    const arch = @tagName(target.result.cpu.arch);
    const limine = b.dependency("limine", .{});
    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_source_file = b.path("kernel/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
        .strip = b.option(bool, "strip", "Strip the kernel") orelse switch (optimize) {
            .Debug, .ReleaseSafe => false,
            .ReleaseFast, .ReleaseSmall => true,
        },
        // .omit_frame_pointer = false,
        // .pic = true,
    });
    kernel.root_module.addImport("limine", limine.module("limine"));
    kernel.root_module.addImport("ubik", b.createModule(.{ .root_source_file = b.path("lib/ubik.zig") }));
    kernel.pie = true;
    kernel.root_module.red_zone = false;
    // kernel.root_module.stack_check = false;
    // kernel.want_lto = false;
    kernel.setLinkerScriptPath(b.path(concat(b, &[_][]const u8{ "kernel/linker-", arch, ".ld" })));

    return kernel;
}

fn findModules(b: *std.Build) []const u8 {
    var modules = std.ArrayList([]const u8).init(b.allocator);
    const config = @embedFile("limine.conf");
    var iter = std.mem.splitAny(u8, config, &std.ascii.whitespace);

    while (iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "module_path: boot():") and
            !std.mem.endsWith(u8, line, ".tar"))
        {
            const i = std.mem.lastIndexOfScalar(u8, line, '/') orelse unreachable;
            modules.append(line[i + 1 ..]) catch unreachable;
        }
    }

    var modules_str: []const u8 = "";
    for (modules.items) |module| {
        modules_str = concat(b, &[_][]const u8{ modules_str, module, " " });
    }

    return modules_str;
}

fn buildImage(b: *std.Build, image_name: []const u8) *std.Build.Step.Run {
    const image_dir = b.cache_root.join(b.allocator, &[_][]const u8{"image_root/"}) catch unreachable;

    const image_params = &[_][]const u8{
        "/bin/sh", "-c",
        concat(b, &[_][]const u8{
            "make -C limine && ",
            "mkdir -p ", image_dir, " && ",
            "tar -cf ", image_dir, "base.tar base && ",
            "cp zig-out/bin/kernel.elf limine.conf limine/limine-bios.sys ",
                "limine/limine-bios-cd.bin limine/limine-uefi-cd.bin ",
                findModules(b), image_dir, " && ",
            "mkdir -p ", image_dir, "EFI/BOOT && ",
            "cp limine/BOOTX64.EFI ", image_dir, "EFI/BOOT/ && ",
            "cp limine/BOOTIA32.EFI ", image_dir, "EFI/BOOT/ && ",
            "xorriso -as mkisofs -b limine-bios-cd.bin ",
                "-no-emul-boot -boot-load-size 4 -boot-info-table ",
                "--efi-boot limine-uefi-cd.bin ",
                "-efi-boot-part --efi-boot-image --protective-msdos-label ",
                image_dir, " -o ", image_name, " && ",
            "./limine/limine bios-install ", image_name, " && ",
            "rm -rf ", image_dir,
        })
    };

    return b.addSystemCommand(image_params);
}

pub fn build(b: *std.Build) void {
    const kernel = buildKernel(b);
    b.installArtifact(kernel);

    const arch = @tagName(kernel.rootModuleTarget().cpu.arch);
    const image_name = concat(b, &[_][]const u8{ "ubik-", arch, ".iso" });
    const image_step = b.step("image", "Build the image");
    const image_cmd = buildImage(b, image_name);
    image_cmd.step.dependOn(b.getInstallStep());
    image_step.dependOn(&image_cmd.step);

    const run_step = b.step("run", "Run the image with qemu");
    const nodisplay = b.option(bool, "nodisplay", "Disable display for qemu") orelse false;
    const run_cmd = b.addSystemCommand(&[_][]const u8{
        concat(b, &[_][]const u8{ "qemu-system-", arch }),
        "-no-reboot",
        "-serial", "stdio",
        "-M", "q35",
        "-m", "1G",
        "-smp", "4",
        // "-d", "int,guest_errors",
        "-boot", "d",
        "-vga", "std",
        "-display", if (nodisplay) "none" else "gtk",
        "-cdrom", image_name
    });
    run_cmd.step.dependOn(image_step);
    run_step.dependOn(&run_cmd.step);

    const docs_step = b.step("docs", "Generate documentations");
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = kernel.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);

    const fmt_step = b.step("fmt", "Format all source files");
    fmt_step.dependOn(&b.addFmt(.{ .paths = &[_][]const u8{ "kernel", "lib" } }).step);

    const clean_step = b.step("clean", "Remove build artifacts");
    clean_step.dependOn(&b.addRemoveDirTree(b.path(".zig-cache")).step);
    clean_step.dependOn(&b.addRemoveDirTree(b.path("zig-out")).step);
    clean_step.dependOn(&b.addRemoveDirTree(b.path(image_name)).step);
}
