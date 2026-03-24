const std = @import("std");

const SpirvShaderPair = struct {
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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm_spirv = b.option(bool, "llvm-spirv", "Use LLVM backend for SPIR-V shader builds") orelse false;
    _ = use_llvm_spirv; // autofix
    const compare_spirv = b.option(bool, "compare-spirv", "Emit SPIR-V size comparison for GA vs raw shader variants") orelse false;
    _ = compare_spirv; // autofix

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_simd_fast_paths", true);
    const simd_build_options_module = build_options.createModule();

    const zmath = b.addModule("zmath", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{
                .name = "build_options",
                .module = simd_build_options_module,
            },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zmath",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "zmath",
                    .module = zmath,
                },
                .{
                    .name = "build_options",
                    .module = simd_build_options_module,
                },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const bench_optimize = .ReleaseFast;

    const bench_simd_exe = b.addExecutable(.{
        .name = "zmath-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = bench_optimize,
            .imports = &.{
                .{
                    .name = "zmath",
                    .module = zmath,
                },
                .{
                    .name = "build_options",
                    .module = simd_build_options_module,
                },
            },
        }),
    });

    const bench_scalar_options = b.addOptions();
    bench_scalar_options.addOption(bool, "enable_simd_fast_paths", false);
    const scalar_build_options_module = bench_scalar_options.createModule();
    const bench_scalar_zmath = b.addModule("zmath-bench-scalar", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{
                .name = "build_options",
                .module = scalar_build_options_module,
            },
        },
    });

    const bench_scalar_exe = b.addExecutable(.{
        .name = "zmath-bench-scalar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_scalar.zig"),
            .target = target,
            .optimize = bench_optimize,
            .imports = &.{
                .{
                    .name = "zmath",
                    .module = bench_scalar_zmath,
                },
                .{
                    .name = "build_options",
                    .module = scalar_build_options_module,
                },
            },
        }),
    });

    const bench_simd_step = b.step("bench-simd", "Run micro-benchmarks with SIMD fast paths (ReleaseFast)");
    const run_bench_simd = b.addRunArtifact(bench_simd_exe);
    bench_simd_step.dependOn(&run_bench_simd.step);

    const bench_scalar_step = b.step("bench-scalar", "Run micro-benchmarks with scalar fallback paths (ReleaseFast)");
    const run_bench_scalar = b.addRunArtifact(bench_scalar_exe);
    bench_scalar_step.dependOn(&run_bench_scalar.step);

    const bench_step = b.step("bench", "Run scalar and SIMD micro-benchmarks (ReleaseFast)");
    const run_bench_scalar_then_simd = b.addRunArtifact(bench_simd_exe);
    run_bench_scalar_then_simd.step.dependOn(&run_bench_scalar.step);
    bench_step.dependOn(&run_bench_scalar_then_simd.step);

    // const spirv_target = b.resolveTargetQuery(.{
    //     .cpu_arch = .spirv32,
    //     .os_tag = .vulkan,
    //     .cpu_model = .{
    //         .explicit = &std.Target.spirv.cpu.vulkan_v1_2,
    //     },
    //     .ofmt = .spirv,
    //     .abi = .none,
    // });
    //
    // const spirv_build_options = b.addOptions();
    // spirv_build_options.addOption(bool, "enable_simd_fast_paths", true);
    // const spirv_build_options_module = spirv_build_options.createModule();
    // const spirv_ga = b.addModule("ga-spirv", .{
    //     .root_source_file = b.path("src/ga.zig"),
    //     .target = spirv_target,
    //     .imports = &.{
    //         .{
    //             .name = "build_options",
    //             .module = spirv_build_options_module,
    //         },
    //     },
    // });
    // const spirv_vga = b.addModule("vga-spirv", .{
    //     .root_source_file = b.path("src/vga.zig"),
    //     .target = spirv_target,
    //     .imports = &.{
    //         .{
    //             .name = "ga",
    //             .module = spirv_ga,
    //         },
    //         .{
    //             .name = "build_options",
    //             .module = spirv_build_options_module,
    //         },
    //     },
    // });
    //
    // const spirv_step = b.step("spirv-vga", "Build the VGA-based SPIR-V vertex and fragment shaders");
    // const spirv_compare_step = b.step("spirv-compare", "Build GA and raw SPIR-V vertex shader variants for size comparison");
    //
    // const spirv_shader_imports = [_]std.Build.Module.Import{
    //     .{
    //         .name = "vga",
    //         .module = spirv_vga,
    //     },
    //     .{
    //         .name = "build_options",
    //         .module = spirv_build_options_module,
    //     },
    // };
    //
    // const spirv_shaders = SpirvShaderPair.init("vga_passthrough");
    // spirv_shaders.build(b, .{
    //     .target = spirv_target,
    //     .optimize = optimize,
    //     .use_llvm = use_llvm_spirv,
    //     .imports = &spirv_shader_imports,
    //     .install_step = b.getInstallStep(),
    //     .pair_step = spirv_step,
    // });
    //
    // const raw_vert = b.addObject(.{
    //     .name = "vga_passthrough_raw.vert",
    //     .root_module = b.createModule(.{
    //         .root_source_file = b.path("src/shaders/vga_passthrough_raw.vert.zig"),
    //         .target = spirv_target,
    //         .optimize = optimize,
    //         .strip = true,
    //         .imports = &.{
    //             .{
    //                 .name = "build_options",
    //                 .module = spirv_build_options_module,
    //             },
    //         },
    //     }),
    //     .use_llvm = use_llvm_spirv,
    //     .use_lld = false,
    // });
    // const install_raw_vert = b.addInstallFile(raw_vert.getEmittedBin(), "shaders/vga_passthrough_raw.vert.spv");
    // spirv_compare_step.dependOn(&raw_vert.step);
    // spirv_compare_step.dependOn(&install_raw_vert.step);
    //
    // const ga_vert = b.addObject(.{
    //     .name = "vga_passthrough.vert",
    //     .root_module = b.createModule(.{
    //         .root_source_file = b.path("src/shaders/vga_passthrough.vert.zig"),
    //         .target = spirv_target,
    //         .optimize = optimize,
    //         .strip = true,
    //         .imports = &spirv_shader_imports,
    //     }),
    //     .use_llvm = use_llvm_spirv,
    //     .use_lld = false,
    // });
    // const install_ga_vert = b.addInstallFile(ga_vert.getEmittedBin(), "shaders/vga_passthrough_ga.vert.spv");
    // spirv_compare_step.dependOn(&ga_vert.step);
    // spirv_compare_step.dependOn(&install_ga_vert.step);
    //
    // if (compare_spirv) {
    //     const compare_sizes_cmd = b.addSystemCommand(&.{ "sh", "-c", "wc -c zig-out/shaders/vga_passthrough_ga.vert.spv zig-out/shaders/vga_passthrough_raw.vert.spv" });
    //     compare_sizes_cmd.step.dependOn(&install_ga_vert.step);
    //     compare_sizes_cmd.step.dependOn(&install_raw_vert.step);
    //     spirv_compare_step.dependOn(&compare_sizes_cmd.step);
    // }

    const zmath_tests = b.addTest(.{
        .root_module = zmath,
    });

    const run_mod_tests = b.addRunArtifact(zmath_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const scalar_zmath = b.addModule("zmath-scalar", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{
                .name = "build_options",
                .module = scalar_build_options_module,
            },
        },
    });

    const scalar_zmath_tests = b.addTest(.{
        .root_module = scalar_zmath,
    });
    const run_scalar_mod_tests = b.addRunArtifact(scalar_zmath_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_scalar_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
