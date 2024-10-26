const std = @import("std");
const builtin = @import("builtin");

fn concat(b: *std.Build, slices: []const []const u8) []u8 {
    return std.mem.concat(b.allocator, u8, slices) catch @panic("OOM");
}

fn buildKernel(b: *std.Build) *std.Build.Step.Compile {
    const arch = b.option(std.Target.Cpu.Arch, "arch", "The target CPU architecture") orelse .x86_64;
    var target_query: std.Target.Query = .{
        .cpu_arch = arch,
        .os_tag = .freestanding,
        .abi = .none,
    };

    switch (arch) {
        .x86_64 => {
            // Disable CPU features that require additional initialization
            // like MMX, SSE/2 and AVX. That requires us to enable the soft-float feature.
            const Feature = std.Target.x86.Feature;
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.mmx));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.sse));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.sse2));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.avx));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.avx2));
            target_query.cpu_features_add.addFeature(@intFromEnum(Feature.soft_float));
        },
        .aarch64 => {
            const Feature = std.Target.aarch64.Feature;
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.fp_armv8));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.crypto));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.neon));
        },
        .riscv64 => {
            const Feature = std.Target.riscv.Feature;
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.d));
        },
        else => std.debug.panic("Unsupported CPU architecture: {s}", .{@tagName(arch)}),
    }

    const target = b.resolveTargetQuery(target_query);
    const optimize = b.standardOptimizeOption(.{});
    const limine = b.dependency("limine", .{}).module("limine");
    const ubik = b.createModule(.{ .root_source_file = b.path("lib/ubik.zig") });
    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_source_file = b.path("kernel/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = if (arch == .x86_64) .kernel else .default,
        .strip = b.option(bool, "strip", "Strip the kernel") orelse switch (optimize) {
            .Debug, .ReleaseSafe => false,
            .ReleaseFast, .ReleaseSmall => true,
        },
        // .omit_frame_pointer = false,
        // .pic = true,
    });
    kernel.root_module.addImport("limine", limine);
    kernel.root_module.addImport("ubik", ubik);
    kernel.pie = true;
    kernel.root_module.red_zone = false;
    kernel.root_module.stack_check = false;
    kernel.want_lto = false;
    kernel.setLinkerScriptPath(b.path(concat(b, &[_][]const u8{ "kernel/linker-", @tagName(arch), ".ld" })));

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

    return std.mem.join(b.allocator, " ", modules.items) catch @panic("OOM");
}

fn buildImage(b: *std.Build, image_name: []const u8) *std.Build.Step.Run {
    const image_dir = ".zig-cache/image_root/";

    // zig fmt: off
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
        }),
    };
    // zig fmt: on

    return b.addSystemCommand(image_params);
}

pub fn build(b: *std.Build) void {
    comptime {
        const current_zig = builtin.zig_version;
        const min_zig = std.SemanticVersion.parse("0.14.0-dev.1637+8c232922b") catch unreachable;
        if (current_zig.order(min_zig) == .lt) {
            @compileError(std.fmt.comptimePrint(
                \\Your zig version ({}) does not meet the minimum required version ({})
            , .{ current_zig, min_zig }));
        }
    }

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
    // zig fmt: off
    const run_cmd = b.addSystemCommand(&[_][]const u8{
        concat(b, &[_][]const u8{ "qemu-system-", arch }),
        "-no-reboot",
        "-serial", "stdio",
        "-M", "q35",
        "-m", "1G",
        "-smp", "4",
        // "-d", "int,guest_errors",
        // "-s", "-S",
        "-boot", "d",
        "-vga", "std",
        "-display", if (nodisplay) "none" else "gtk",
        "-cdrom", image_name
    });
    // zig fmt: on
    run_cmd.step.dependOn(image_step);
    run_step.dependOn(&run_cmd.step);

    const docs_step = b.step("docs", "Generate documentations");
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = kernel.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);

    const fmt_step = b.step("fmt", "Format all source files");
    fmt_step.dependOn(&b.addFmt(.{ .paths = &[_][]const u8{
        "kernel",
        "lib",
        "build.zig",
    } }).step);

    const clean_step = b.step("clean", "Remove build artifacts");
    clean_step.dependOn(&b.addRemoveDirTree(b.path(".zig-cache")).step);
    clean_step.dependOn(&b.addRemoveDirTree(b.path("zig-out")).step);
    clean_step.dependOn(&b.addRemoveDirTree(b.path(image_name)).step);
}
