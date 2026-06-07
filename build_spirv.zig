const std = @import("std");

pub const SpirvShaderPair = struct {
    const Config = struct {
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        use_llvm: bool,
        imports: []const std.Build.Module.Import,
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

        const optimized_vert = optimizeSpirv(b, vert.getEmittedBin(), b.fmt("{s}.vert.opt.spv", .{self.name}));
        const optimized_frag = optimizeSpirv(b, frag.getEmittedBin(), b.fmt("{s}.frag.opt.spv", .{self.name}));
        const install_vert = b.addInstallFile(optimized_vert, b.fmt("shaders/{s}.vert.spv", .{self.name}));
        const install_frag = b.addInstallFile(optimized_frag, b.fmt("shaders/{s}.frag.spv", .{self.name}));

        cfg.pair_step.dependOn(&vert.step);
        cfg.pair_step.dependOn(&install_vert.step);
        cfg.pair_step.dependOn(&frag.step);
        cfg.pair_step.dependOn(&install_frag.step);
    }
};

fn optimizeSpirv(b: *std.Build, input: std.Build.LazyPath, basename: []const u8) std.Build.LazyPath {
    const optimize_cmd = b.addSystemCommand(&.{
        "spirv-opt",
        "--skip-validation",
        "--eliminate-dead-functions",
        "--eliminate-dead-code-aggressive",
        "--eliminate-local-single-block",
        "--eliminate-local-single-store",
    });
    optimize_cmd.addFileArg(input);
    optimize_cmd.addArg("-o");
    return optimize_cmd.addOutputFileArg(basename);
}

pub const SpirvSteps = struct {
    vga: *std.Build.Step,
    raw: *std.Build.Step,
    compare: *std.Build.Step,
};

pub fn addSpirvSteps(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    use_llvm_spirv: bool,
    compare_spirv: bool,
) SpirvSteps {
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

    const spirv_meta = b.addModule("meta-spirv", .{
        .root_source_file = b.path("src/meta.zig"),
        .target = spirv_target,
    });

    const spirv_parse = b.addModule("parse-spirv", .{
        .root_source_file = b.path("src/parse.zig"),
        .target = spirv_target,
        .imports = &.{.{
            .name = "meta",
            .module = spirv_meta,
        }},
    });

    const spirv_ga = b.addModule("ga-spirv", .{
        .root_source_file = b.path("src/ga.zig"),
        .target = spirv_target,
        .imports = &.{
            .{
                .name = "meta",
                .module = spirv_meta,
            },
            .{
                .name = "parse",
                .module = spirv_parse,
            },
            .{
                .name = "build_options",
                .module = spirv_build_options_module,
            },
        },
    });

    spirv_ga.addImport("ga", spirv_ga);

    const spirv_vga = b.addModule("vga-spirv", .{
        .root_source_file = b.path("src/flavours/vga.zig"),
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
    const spirv_raw_step = b.step("spirv-raw", "Build raw SPIR-V vertex and fragment shaders for driver baselines");
    const spirv_compare_step = b.step("spirv-compare", "Build GA and raw SPIR-V vertex shader variants for size comparison");

    const spirv_shader_imports = [_]std.Build.Module.Import{
        .{
            .name = "ga",
            .module = spirv_ga,
        },
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
        .pair_step = spirv_step,
    });

    const raw_shader_imports = [_]std.Build.Module.Import{.{
        .name = "build_options",
        .module = spirv_build_options_module,
    }};

    const raw_vert = b.addObject(.{
        .name = "vga_passthrough_raw.vert",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shaders/vga_passthrough_compare_raw.vert.zig"),
            .target = spirv_target,
            .optimize = optimize,
            .strip = true,
            .imports = &raw_shader_imports,
        }),
        .use_llvm = use_llvm_spirv,
        .use_lld = false,
    });
    const optimized_raw_vert = optimizeSpirv(b, raw_vert.getEmittedBin(), "vga_passthrough_raw.vert.opt.spv");
    const install_raw_vert = b.addInstallFile(optimized_raw_vert, "shaders/vga_passthrough_raw.vert.spv");
    spirv_raw_step.dependOn(&raw_vert.step);
    spirv_raw_step.dependOn(&install_raw_vert.step);
    spirv_compare_step.dependOn(&raw_vert.step);
    spirv_compare_step.dependOn(&install_raw_vert.step);

    const raw_frag = b.addObject(.{
        .name = "vga_passthrough_raw.frag",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shaders/vga_passthrough_raw.frag.zig"),
            .target = spirv_target,
            .optimize = optimize,
            .strip = true,
            .imports = &raw_shader_imports,
        }),
        .use_llvm = use_llvm_spirv,
        .use_lld = false,
    });
    const optimized_raw_frag = optimizeSpirv(b, raw_frag.getEmittedBin(), "vga_passthrough_raw.frag.opt.spv");
    const install_raw_frag = b.addInstallFile(optimized_raw_frag, "shaders/vga_passthrough_raw.frag.spv");
    spirv_raw_step.dependOn(&raw_frag.step);
    spirv_raw_step.dependOn(&install_raw_frag.step);

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
    const optimized_ga_vert = optimizeSpirv(b, ga_vert.getEmittedBin(), "vga_passthrough_ga.vert.opt.spv");
    const install_ga_vert = b.addInstallFile(optimized_ga_vert, "shaders/vga_passthrough_ga.vert.spv");
    spirv_compare_step.dependOn(&ga_vert.step);
    spirv_compare_step.dependOn(&install_ga_vert.step);

    if (compare_spirv) {
        const compare_sizes_cmd = b.addSystemCommand(&.{ "sh", "-c", "wc -c zig-out/shaders/vga_passthrough_ga.vert.spv zig-out/shaders/vga_passthrough_raw.vert.spv" });
        compare_sizes_cmd.step.dependOn(&install_ga_vert.step);
        compare_sizes_cmd.step.dependOn(&install_raw_vert.step);
        spirv_compare_step.dependOn(&compare_sizes_cmd.step);
    }

    return .{
        .vga = spirv_step,
        .raw = spirv_raw_step,
        .compare = spirv_compare_step,
    };
}
