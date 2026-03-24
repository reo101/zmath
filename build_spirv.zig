const std = @import("std");

pub const SpirvShaderPair = struct {
    const Config = struct {
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        use_llvm: bool,
        imports: []const std.Build.Module.Import,
        install_step: *std.Build.Step,
        pair_step: *std.Build.Step,
    };

    name: []const u8,

    pub fn init(name: []const u8) SpirvShaderPair {
        return .{ .name = name };
    }

    pub fn build(self: SpirvShaderPair, b: *std.Build, cfg: Config) void {
        const vert = b.addObject(.{
            .name = b.fmt("{s}.vert", .{self.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/shaders/{s}.vert.zig", .{self.name})),
                .target = cfg.target,
                .optimize = cfg.optimize,
                .strip = true,
                .imports = cfg.imports,
            }),
            .use_llvm = cfg.use_llvm,
            .use_lld = false,
        });

        const frag = b.addObject(.{
            .name = b.fmt("{s}.frag", .{self.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/shaders/{s}.frag.zig", .{self.name})),
                .target = cfg.target,
                .optimize = cfg.optimize,
                .strip = true,
                .imports = cfg.imports,
            }),
            .use_llvm = cfg.use_llvm,
            .use_lld = false,
        });

        const install_vert = b.addInstallFile(vert.getEmittedBin(), b.fmt("shaders/{s}.vert.spv", .{self.name}));
        const install_frag = b.addInstallFile(frag.getEmittedBin(), b.fmt("shaders/{s}.frag.spv", .{self.name}));

        cfg.install_step.dependOn(&install_vert.step);
        cfg.install_step.dependOn(&install_frag.step);

        cfg.pair_step.dependOn(&vert.step);
        cfg.pair_step.dependOn(&install_vert.step);
        cfg.pair_step.dependOn(&frag.step);
        cfg.pair_step.dependOn(&install_frag.step);
    }
};

pub fn addSpirvSteps(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    use_llvm_spirv: bool,
    compare_spirv: bool,
) void {
    const spirv_target = b.resolveTargetQuery(.{
        .cpu_arch = .spirv32,
        .os_tag = .vulkan,
        .cpu_model = .{
            .explicit = &std.Target.spirv.cpu.vulkan_v1_2,
        },
        .ofmt = .spirv,
        .abi = .none,
    });

    const spirv_build_options = b.addOptions();
    spirv_build_options.addOption(bool, "enable_simd_fast_paths", true);
    const spirv_build_options_module = spirv_build_options.createModule();

    const spirv_ga = b.addModule("ga-spirv", .{
        .root_source_file = b.path("src/ga.zig"),
        .target = spirv_target,
        .imports = &.{
            .{
                .name = "build_options",
                .module = spirv_build_options_module,
            },
        },
    });

    const spirv_vga = b.addModule("vga-spirv", .{
        .root_source_file = b.path("src/vga.zig"),
        .target = spirv_target,
        .imports = &.{
            .{
                .name = "ga",
                .module = spirv_ga,
            },
            .{
                .name = "build_options",
                .module = spirv_build_options_module,
            },
        },
    });

    const spirv_step = b.step("spirv-vga", "Build the VGA-based SPIR-V vertex and fragment shaders");
    const spirv_compare_step = b.step("spirv-compare", "Build GA and raw SPIR-V vertex shader variants for size comparison");

    const spirv_shader_imports = [_]std.Build.Module.Import{
        .{
            .name = "vga",
            .module = spirv_vga,
        },
        .{
            .name = "build_options",
            .module = spirv_build_options_module,
        },
    };

    const spirv_shaders = SpirvShaderPair.init("vga_passthrough");
    spirv_shaders.build(b, .{
        .target = spirv_target,
        .optimize = optimize,
        .use_llvm = use_llvm_spirv,
        .imports = &spirv_shader_imports,
        .install_step = b.getInstallStep(),
        .pair_step = spirv_step,
    });

    const raw_vert = b.addObject(.{
        .name = "vga_passthrough_raw.vert",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shaders/vga_passthrough_raw.vert.zig"),
            .target = spirv_target,
            .optimize = optimize,
            .strip = true,
            .imports = &.{
                .{
                    .name = "build_options",
                    .module = spirv_build_options_module,
                },
            },
        }),
        .use_llvm = use_llvm_spirv,
        .use_lld = false,
    });
    const install_raw_vert = b.addInstallFile(raw_vert.getEmittedBin(), "shaders/vga_passthrough_raw.vert.spv");
    spirv_compare_step.dependOn(&raw_vert.step);
    spirv_compare_step.dependOn(&install_raw_vert.step);

    const ga_vert = b.addObject(.{
        .name = "vga_passthrough.vert",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shaders/vga_passthrough.vert.zig"),
            .target = spirv_target,
            .optimize = optimize,
            .strip = true,
            .imports = &spirv_shader_imports,
        }),
        .use_llvm = use_llvm_spirv,
        .use_lld = false,
    });
    const install_ga_vert = b.addInstallFile(ga_vert.getEmittedBin(), "shaders/vga_passthrough_ga.vert.spv");
    spirv_compare_step.dependOn(&ga_vert.step);
    spirv_compare_step.dependOn(&install_ga_vert.step);

    if (compare_spirv) {
        const compare_sizes_cmd = b.addSystemCommand(&.{ "sh", "-c", "wc -c zig-out/shaders/vga_passthrough_ga.vert.spv zig-out/shaders/vga_passthrough_raw.vert.spv" });
        compare_sizes_cmd.step.dependOn(&install_ga_vert.step);
        compare_sizes_cmd.step.dependOn(&install_raw_vert.step);
        spirv_compare_step.dependOn(&compare_sizes_cmd.step);
    }
}
