const std = @import("std");
const build_spirv = @import("build_spirv.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm_spirv = b.option(bool, "llvm-spirv", "Use LLVM backend for SPIR-V shader builds") orelse false;
    const compare_spirv = b.option(bool, "compare-spirv", "Emit SPIR-V size comparison for GA vs raw shader variants") orelse false;
    const fuzz_use_llvm = b.option(bool, "fuzz-llvm", "Force LLVM backend for fuzz test builds") orelse true;

    const build_options = b.addOptions();
    build_options.step.name = "options simd-build";
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
    bench_scalar_options.step.name = "options scalar-build";
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

    build_spirv.addSpirvSteps(b, optimize, use_llvm_spirv, compare_spirv);

    const zmath_tests = b.addTest(.{
        .name = "zmath-module",
        .root_module = zmath,
    });

    const run_mod_tests = b.addRunArtifact(zmath_tests);
    run_mod_tests.setName("run test zmath-module");

    // Demos
    const demo_exe = b.addExecutable(.{
        .name = "zmath-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demos/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "zmath",
                    .module = zmath,
                },
            },
        }),
    });
    b.installArtifact(demo_exe);

    const demo_run_cmd = b.addRunArtifact(demo_exe);
    const demo_step = b.step("demo", "Run the demo");
    demo_step.dependOn(&demo_run_cmd.step);

    const raylib_dep = b.dependency("raylib", .{
        .target = target,
        .optimize = optimize,
        .linkage = .dynamic,
        .raudio = false,
        .rmodels = false,
        .linux_display_backend = .X11,
    });
    const raylib = raylib_dep.artifact("raylib");

    const demo_raylib_exe = b.addExecutable(.{
        .name = "zmath-demo-raylib",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demos/raylib_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{
                    .name = "zmath",
                    .module = zmath,
                },
            },
        }),
    });
    demo_raylib_exe.root_module.linkLibrary(raylib);
    demo_raylib_exe.root_module.addIncludePath(raylib_dep.path("src"));

    const demo_raylib_build_step = b.step("demo-raylib-build", "Build the raylib demo backend");
    demo_raylib_build_step.dependOn(&demo_raylib_exe.step);

    const demo_raylib_run_cmd = b.addRunArtifact(demo_raylib_exe);
    const demo_raylib_step = b.step("demo-raylib", "Run the demo with the raylib backend");
    demo_raylib_step.dependOn(&demo_raylib_run_cmd.step);

    const exe_tests = b.addTest(.{
        .name = "zmath-cli",
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.setName("run test zmath-cli");

    const expression_fuzz_tests = b.addTest(.{
        .name = "zmath-expression-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ga/expression_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "build_options",
                    .module = simd_build_options_module,
                },
            },
        }),
        .filters = &.{"expression.test.expression fuzz:"},
        .use_llvm = fuzz_use_llvm,
    });

    const run_expression_fuzz = b.addRunArtifact(expression_fuzz_tests);
    run_expression_fuzz.setName("run fuzz test zmath-expression");

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
        .name = "zmath-module-scalar",
        .root_module = scalar_zmath,
    });
    const run_scalar_mod_tests = b.addRunArtifact(scalar_zmath_tests);
    run_scalar_mod_tests.setName("run test zmath-module-scalar");

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_scalar_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const fuzz_expr_step = b.step("fuzz-expr", "Run the expression parser/evaluator fuzz smoke test");
    fuzz_expr_step.dependOn(&run_expression_fuzz.step);
}
