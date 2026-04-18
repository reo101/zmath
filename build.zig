const std = @import("std");
const build_spirv = @import("build_spirv.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm_spirv = b.option(bool, "llvm-spirv", "Use LLVM backend for SPIR-V shader builds") orelse false;
    const compare_spirv = b.option(bool, "compare-spirv", "Emit SPIR-V size comparison for GA vs raw shader variants") orelse false;
    const fuzz_use_llvm = b.option(bool, "fuzz-llvm", "Force LLVM backend for fuzz test builds") orelse true;

    const zmath = b.addModule("zmath", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
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
            },
        }),
    });

    const bench_simd_step = b.step("bench-simd", "Run micro-benchmarks with SIMD fast paths (ReleaseFast)");
    const run_bench_simd = b.addRunArtifact(bench_simd_exe);
    bench_simd_step.dependOn(&run_bench_simd.step);

    build_spirv.addSpirvSteps(b, optimize, use_llvm_spirv, compare_spirv);

    const zmath_tests = b.addTest(.{
        .name = "zmath-module",
        .root_module = zmath,
    });

    const run_mod_tests = b.addRunArtifact(zmath_tests);
    run_mod_tests.setName("run test zmath-module");

    const profile_multivector_exe = b.addExecutable(.{
        .name = "zmath-profile-multivector",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/profile/multivector.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{
                    .name = "zmath",
                    .module = zmath,
                },
            },
        }),
    });

    const profile_multivector_step = b.step(
        "profile-multivector-build",
        "Compile the comptime multivector profiling harness",
    );
    profile_multivector_step.dependOn(&profile_multivector_exe.step);

    const profile_curved_demo_exe = b.addExecutable(.{
        .name = "zmath-profile-curved-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/profile/curved_demo.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{
                    .name = "zmath",
                    .module = zmath,
                },
                .{
                    .name = "demo_core",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/demos/core.zig"),
                        .target = target,
                        .optimize = .Debug,
                        .imports = &.{
                            .{
                                .name = "zmath",
                                .module = zmath,
                            },
                        },
                    }),
                },
            },
        }),
    });

    const profile_curved_demo_step = b.step(
        "profile-curved-demo",
        "Render fixed curved-demo snapshots for inspection",
    );
    const run_profile_curved_demo = b.addRunArtifact(profile_curved_demo_exe);
    profile_curved_demo_step.dependOn(&run_profile_curved_demo.step);

    const profile_spherical_walk_trace_exe = b.addExecutable(.{
        .name = "zmath-profile-spherical-walk-trace",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/profile/spherical_walk_trace.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{
                    .name = "zmath",
                    .module = zmath,
                },
                .{
                    .name = "demo_core",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/demos/core.zig"),
                        .target = target,
                        .optimize = .Debug,
                        .imports = &.{
                            .{
                                .name = "zmath",
                                .module = zmath,
                            },
                        },
                    }),
                },
            },
        }),
    });

    const profile_spherical_walk_trace_step = b.step(
        "profile-spherical-walk-trace",
        "Trace spherical demo vertex paths while walking backward from a repro state",
    );
    const run_profile_spherical_walk_trace = b.addRunArtifact(profile_spherical_walk_trace_exe);
    profile_spherical_walk_trace_step.dependOn(&run_profile_spherical_walk_trace.step);

    const profile_spherical_walk_reversibility_exe = b.addExecutable(.{
        .name = "zmath-profile-spherical-walk-reversibility",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/profile/spherical_walk_reversibility.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{
                    .name = "zmath",
                    .module = zmath,
                },
                .{
                    .name = "demo_core",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/demos/core.zig"),
                        .target = target,
                        .optimize = .Debug,
                        .imports = &.{
                            .{
                                .name = "zmath",
                                .module = zmath,
                            },
                        },
                    }),
                },
            },
        }),
    });

    const profile_spherical_walk_reversibility_step = b.step(
        "profile-spherical-walk-reversibility",
        "Trace when spherical backward walking stops being reversible",
    );
    const run_profile_spherical_walk_reversibility = b.addRunArtifact(profile_spherical_walk_reversibility_exe);
    profile_spherical_walk_reversibility_step.dependOn(&run_profile_spherical_walk_reversibility.step);

    const profile_spherical_sphere_map_exe = b.addExecutable(.{
        .name = "zmath-profile-spherical-sphere-map",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/profile/spherical_sphere_map.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{
                    .name = "zmath",
                    .module = zmath,
                },
                .{
                    .name = "demo_core",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/demos/core.zig"),
                        .target = target,
                        .optimize = .Debug,
                        .imports = &.{
                            .{
                                .name = "zmath",
                                .module = zmath,
                            },
                        },
                    }),
                },
            },
        }),
    });

    const profile_spherical_sphere_map_step = b.step(
        "profile-spherical-sphere-map",
        "ASCII sphere-map showing vertex positions on S3 relative to camera during walk",
    );
    const run_profile_spherical_sphere_map = b.addRunArtifact(profile_spherical_sphere_map_exe);
    profile_spherical_sphere_map_step.dependOn(&run_profile_spherical_sphere_map.step);

    const profile_spherical_steep_walk_probe_exe = b.addExecutable(.{
        .name = "zmath-profile-spherical-steep-walk-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/profile/spherical_steep_walk_probe.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{
                    .name = "zmath",
                    .module = zmath,
                },
                .{
                    .name = "demo_core",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/demos/core.zig"),
                        .target = target,
                        .optimize = .Debug,
                        .imports = &.{
                            .{
                                .name = "zmath",
                                .module = zmath,
                            },
                        },
                    }),
                },
            },
        }),
    });

    const profile_spherical_steep_walk_probe_step = b.step(
        "profile-spherical-steep-walk-probe",
        "Trace steep-pitch backward walking in spherical mode and report the first camera jump",
    );
    const run_profile_spherical_steep_walk_probe = b.addRunArtifact(profile_spherical_steep_walk_probe_exe);
    profile_spherical_steep_walk_probe_step.dependOn(&run_profile_spherical_steep_walk_probe.step);

    const profile_spherical_motion_probe_exe = b.addExecutable(.{
        .name = "zmath-profile-spherical-motion-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/profile/spherical_motion_probe.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{
                    .name = "zmath",
                    .module = zmath,
                },
                .{
                    .name = "demo_core",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/demos/core.zig"),
                        .target = target,
                        .optimize = .Debug,
                        .imports = &.{
                            .{
                                .name = "zmath",
                                .module = zmath,
                            },
                        },
                    }),
                },
            },
        }),
    });

    const profile_spherical_motion_probe_step = b.step(
        "profile-spherical-motion-probe",
        "Compare cube and ground screen motion under spherical look and move commands",
    );
    const run_profile_spherical_motion_probe = b.addRunArtifact(profile_spherical_motion_probe_exe);
    profile_spherical_motion_probe_step.dependOn(&run_profile_spherical_motion_probe.step);

    const profile_spherical_ground_probe_exe = b.addExecutable(.{
        .name = "zmath-profile-spherical-ground-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/profile/spherical_ground_probe.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{
                    .name = "zmath",
                    .module = zmath,
                },
                .{
                    .name = "demo_core",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/demos/core.zig"),
                        .target = target,
                        .optimize = .Debug,
                        .imports = &.{
                            .{
                                .name = "zmath",
                                .module = zmath,
                            },
                        },
                    }),
                },
            },
        }),
    });

    const profile_spherical_ground_probe_step = b.step(
        "profile-spherical-ground-probe",
        "Count which spherical ground cells are drawn vs discarded",
    );
    const run_profile_spherical_ground_probe = b.addRunArtifact(profile_spherical_ground_probe_exe);
    profile_spherical_ground_probe_step.dependOn(&run_profile_spherical_ground_probe.step);

    const profile_euclidean_sdf_exe = b.addExecutable(.{
        .name = "zmath-profile-euclidean-sdf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/profile/euclidean_sdf.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{
                    .name = "zmath",
                    .module = zmath,
                },
                .{
                    .name = "demo_euclidean_sdf",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/demos/euclidean_sdf.zig"),
                        .target = target,
                        .optimize = .Debug,
                        .imports = &.{
                            .{
                                .name = "zmath",
                                .module = zmath,
                            },
                        },
                    }),
                },
            },
        }),
    });

    const profile_euclidean_sdf_step = b.step(
        "profile-euclidean-sdf",
        "Benchmark the Euclidean SDF raymarch path without opening a window",
    );
    const run_profile_euclidean_sdf = b.addRunArtifact(profile_euclidean_sdf_exe);
    profile_euclidean_sdf_step.dependOn(&run_profile_euclidean_sdf.step);

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
    const raylib_translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/demos/raylib_c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    raylib_translate_c.addIncludePath(raylib_dep.path("src"));

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
                .{
                    .name = "raylib_c",
                    .module = raylib_translate_c.createModule(),
                },
            },
        }),
    });
    demo_raylib_exe.root_module.linkLibrary(raylib);

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

    const module_surface_tests = b.addTest(.{
        .name = "zmath-module-surfaces",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/tests/modules.zig"),
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

    const run_module_surface_tests = b.addRunArtifact(module_surface_tests);
    run_module_surface_tests.setName("run test zmath-module-surfaces");

    const demo_core_tests = b.addTest(.{
        .name = "zmath-demo-core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demos/core.zig"),
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

    const run_demo_core_tests = b.addRunArtifact(demo_core_tests);
    run_demo_core_tests.setName("run test zmath-demo-core");

    const expression_fuzz_tests = b.addTest(.{
        .name = "zmath-expression-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fuzz/expression.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "zmath",
                    .module = zmath,
                },
            },
        }),
        .use_llvm = fuzz_use_llvm,
    });

    const run_expression_fuzz = b.addRunArtifact(expression_fuzz_tests);
    run_expression_fuzz.setName("run fuzz test zmath-expression");

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_module_surface_tests.step);
    test_step.dependOn(&run_demo_core_tests.step);

    const fuzz_expr_step = b.step("fuzz-expr", "Run the expression parser/evaluator fuzz smoke test");
    fuzz_expr_step.dependOn(&run_expression_fuzz.step);
}
