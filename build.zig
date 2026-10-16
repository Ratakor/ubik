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
            target_query.cpu_features_sub = std.Target.x86.featureSet(&.{ .mmx, .sse, .sse2, .avx, .avx2 });
            target_query.cpu_features_add = std.Target.x86.featureSet(&.{.soft_float});
        },
        .aarch64 => {
            target_query.cpu_features_sub = std.Target.aarch64.featureSet(&.{ .fp_armv8, .crypto, .neon });
        },
        .riscv64 => {
            target_query.cpu_features_sub = std.Target.riscv.featureSet(&.{.d});
        },
        else => std.debug.panic("Unsupported CPU architecture: {s}", .{@tagName(arch)}),
    }

    const target = b.resolveTargetQuery(target_query);
    const optimize = b.standardOptimizeOption(.{});
    const limine = b.createModule(.{
        .root_source_file = b.path("lib/limine/limine.zig"),
        .omit_frame_pointer = false,
    });
    const ubik = b.createModule(.{
        .root_source_file = b.path("lib/ubik.zig"),
        .omit_frame_pointer = false,
    });
    const root_module = b.createModule(.{
        .root_source_file = b.path("kernel/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = if (arch == .x86_64) .kernel else .default,
        .strip = b.option(bool, "strip", "Strip the kernel") orelse switch (optimize) {
            .Debug, .ReleaseSafe => false,
            .ReleaseFast, .ReleaseSmall => true,
        },
        .omit_frame_pointer = false,
        .red_zone = false,
        .stack_check = false,
    });
    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = root_module,
        // The interrupt stubs use LLVM inline-assembly constraints.
        .use_llvm = true,
    });
    kernel.root_module.addImport("limine", limine);
    kernel.root_module.addImport("ubik", ubik);
    kernel.pie = true;

    kernel.lto = .none;
    kernel.setLinkerScript(b.path(concat(b, &[_][]const u8{ "kernel/linker-", @tagName(arch), ".ld" })));

    return kernel;
}

fn findModules(b: *std.Build) []const u8 {
    var modules: std.ArrayList([]const u8) = .empty;
    const config = @embedFile("limine.conf");
    var iter = std.mem.splitAny(u8, config, &std.ascii.whitespace);

    while (iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "module_path: boot():") and
            !std.mem.endsWith(u8, line, ".tar"))
        {
            const i = std.mem.lastIndexOfScalar(u8, line, '/') orelse unreachable;
            modules.append(b.allocator, line[i + 1 ..]) catch unreachable;
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
        const min_zig = std.SemanticVersion.parse("0.16.0") catch unreachable;
        if (current_zig.order(min_zig) == .lt) {
            @compileError(std.fmt.comptimePrint(
                \\Your zig version ({}) does not meet the minimum required version ({})
            , .{ current_zig, min_zig }));
        }
    }

    const kernel = buildKernel(b);
    b.installArtifact(kernel);

    const arch = @tagName(kernel.root_module.resolved_target.?.result.cpu.arch);
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
    clean_step.dependOn(&b.addSystemCommand(&.{ "rm", "-rf", ".zig-cache", "zig-out", image_name }).step);
}
