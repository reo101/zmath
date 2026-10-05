const std = @import("std");

pub const SpirvShaderPair = struct {
    const Config = struct {
        target: std.Build.ResolvedTarget,
        optimize: std.lang.Optimize,
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
    const disassemble = b.addSystemCommand(&.{"spirv-dis"});
    disassemble.addFileArg2(input, .{});
    disassemble.addArg("-o");
    const assembly = disassemble.addOutputFileArg2(b.fmt("{s}.spvasm", .{basename}), .{});

    const patch = b.addSystemCommand(&.{"python3"});
    patch.addFileArg2(b.path("tools/patch_spirv_storage_blocks.py"), .{});
    patch.addFileArg2(assembly, .{});
    patch.addArg("-o");
    const patched_assembly = patch.addOutputFileArg2(b.fmt("{s}.patched.spvasm", .{basename}), .{});

    const assemble = b.addSystemCommand(&.{ "spirv-as", "--target-env", "vulkan1.2" });
    assemble.addFileArg2(patched_assembly, .{});
    assemble.addArg("-o");
    const patched = assemble.addOutputFileArg2(b.fmt("{s}.patched.spv", .{basename}), .{});

    const optimize_cmd = b.addSystemCommand(&.{
        "spirv-opt",
        "--eliminate-dead-functions",
        "--eliminate-dead-code-aggressive",
        "--eliminate-local-single-block",
        "--eliminate-local-single-store",
    });
    optimize_cmd.addFileArg2(patched, .{});
    optimize_cmd.addArg("-o");
    const optimized = optimize_cmd.addOutputFileArg2(basename, .{});
    const validate = b.addSystemCommand(&.{ "spirv-val", "--target-env", "vulkan1.2" });
    validate.addFileArg2(optimized, .{});
    validate.expectExitCode(0);
    const validated = b.addWriteFiles();
    validated.step.dependOn(&validate.step);
    return validated.addCopyFile(optimized, basename);
}

pub const SpirvSteps = struct {
    vga: *std.Build.Step,
    raw: *std.Build.Step,
    compare: *std.Build.Step,
    spherical: *std.Build.Step,
    worlds: *std.Build.Step,
};

pub fn addSpirvSteps(
    b: *std.Build,
    optimize: std.lang.Optimize,
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

    const spirv_spherical_geometry = b.addModule("spherical-geometry-spirv", .{
        .root_source_file = b.path("src/geometry/spherical_game.zig"),
        .target = spirv_target,
        .imports = &.{.{ .name = "ga", .module = spirv_ga }},
    });

    const spirv_step = b.step("spirv-vga", "Build the VGA-based SPIR-V vertex and fragment shaders");
    const spirv_raw_step = b.step("spirv-raw", "Build raw SPIR-V vertex and fragment shaders for driver baselines");
    const spirv_compare_step = b.step("spirv-compare", "Build GA and raw SPIR-V vertex shader variants for size comparison");
    const spirv_spherical_step = b.step("spirv-spherical", "Build the Zig-authored S3 ground SPIR-V shaders");

    const spirv_shader_imports = [_]std.Build.Module.Import{
        .{
            .name = "ga",
            .module = spirv_ga,
        },
        .{
            .name = "spherical_geometry",
            .module = spirv_spherical_geometry,
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

    const vector_interface = b.addObject(.{
        .name = "vector-interface.vert",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/tests/vector_interface.vert.zig"),
            .target = spirv_target,
            .optimize = optimize,
            .strip = true,
            .imports = &spirv_shader_imports,
        }),
        .use_llvm = use_llvm_spirv,
        .use_lld = false,
    });
    const spirv_check_step = b.step("spirv-check", "Validate typed vector interface loads, stores, and member access");
    const checked_interface = optimizeSpirv(b, vector_interface.getEmittedBin(), "vector-interface.vert.spv");
    checked_interface.addStepDependencies(spirv_check_step);

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

    const spherical_shaders = SpirvShaderPair.init("spherical_ground");
    spherical_shaders.build(b, .{
        .target = spirv_target,
        .optimize = optimize,
        .use_llvm = use_llvm_spirv,
        .imports = &spirv_shader_imports,
        .pair_step = spirv_spherical_step,
    });
    const spherical_mesh_shaders = SpirvShaderPair.init("spherical_mesh");
    spherical_mesh_shaders.build(b, .{
        .target = spirv_target,
        .optimize = optimize,
        .use_llvm = use_llvm_spirv,
        .imports = &spirv_shader_imports,
        .pair_step = spirv_spherical_step,
    });

    const spirv_geometry = b.addModule("geometry-worlds-spirv", .{
        .root_source_file = b.path("src/geometry.zig"),
        .target = spirv_target,
        .imports = &.{.{ .name = "ga", .module = spirv_ga }},
    });
    const spirv_zmath = b.addModule("zmath-worlds-spirv", .{
        .root_source_file = b.path("src/root.zig"),
        .target = spirv_target,
        .imports = &.{
            .{ .name = "ga", .module = spirv_ga },
            .{ .name = "parse", .module = spirv_parse },
            .{ .name = "geometry", .module = spirv_geometry },
        },
    });
    const spirv_scene = b.addModule("scene-worlds-spirv", .{
        .root_source_file = b.path("src/demos/spherical_game/scene.zig"),
        .target = spirv_target,
        .imports = &.{.{ .name = "zmath", .module = spirv_zmath }},
    });
    const spirv_worlds_render = b.addModule("render-worlds-spirv", .{
        .root_source_file = b.path("src/demos/worlds/render.zig"),
        .target = spirv_target,
        .imports = &.{
            .{ .name = "zmath", .module = spirv_zmath },
            .{ .name = "spherical_scene", .module = spirv_scene },
        },
    });
    const worlds_frag = b.addObject(.{
        .name = "worlds.frag",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shaders/worlds.frag.zig"),
            .target = spirv_target,
            .optimize = optimize,
            .strip = true,
            .imports = &.{.{ .name = "worlds_render", .module = spirv_worlds_render }},
        }),
        .use_llvm = use_llvm_spirv,
        .use_lld = false,
    });
    const worlds_fragment = optimizeSpirv(b, worlds_frag.getEmittedBin(), "worlds.frag.opt.spv");
    const install_worlds_frag = b.addInstallFile(worlds_fragment, "shaders/worlds.frag.spv");
    const spirv_worlds_step = b.step("spirv-worlds", "Build validated GPU shaders for all four worlds");
    spirv_worlds_step.dependOn(spirv_spherical_step);
    spirv_worlds_step.dependOn(&install_worlds_frag.step);

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
        .spherical = spirv_spherical_step,
        .worlds = spirv_worlds_step,
    };
}
