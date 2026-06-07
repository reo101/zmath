const std = @import("std");
const build_spirv = @import("build_spirv.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm_spirv = b.option(bool, "llvm-spirv", "Use LLVM backend for SPIR-V shader builds") orelse false;
    const compare_spirv = b.option(bool, "compare-spirv", "Emit SPIR-V size comparison for GA vs raw shader variants") orelse false;
    const fuzz_use_llvm = b.option(bool, "fuzz-llvm", "Force LLVM backend for fuzz test builds") orelse true;

    const meta_module = b.addModule("meta", .{
        .root_source_file = b.path("src/meta.zig"),
        .target = target,
    });

    const parse_module = b.addModule("parse", .{
        .root_source_file = b.path("src/parse.zig"),
        .target = target,
        .imports = &.{.{
            .name = "meta",
            .module = meta_module,
        }},
    });

    const ga_module = b.addModule("ga", .{
        .root_source_file = b.path("src/ga.zig"),
        .target = target,
        .imports = &.{
            .{
                .name = "meta",
                .module = meta_module,
            },
            .{
                .name = "parse",
                .module = parse_module,
            },
        },
    });

    ga_module.addImport("ga", ga_module);

    const flavours_module = b.addModule("flavours", .{
        .root_source_file = b.path("src/flavours.zig"),
        .target = target,
        .imports = &.{.{
            .name = "ga",
            .module = ga_module,
        }},
    });

    const geometry_module = b.addModule("geometry", .{
        .root_source_file = b.path("src/geometry.zig"),
        .target = target,
        .imports = &.{
            .{
                .name = "ga",
                .module = ga_module,
            },
            .{
                .name = "flavours",
                .module = flavours_module,
            },
        },
    });

    const render_module = b.addModule("render", .{
        .root_source_file = b.path("src/render.zig"),
        .target = target,
        .imports = &.{.{
            .name = "ga",
            .module = ga_module,
        }},
    });
    geometry_module.addImport("render", render_module);
    render_module.addImport("geometry", geometry_module);

    const zmath = b.addModule("zmath", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{
                .name = "ga",
                .module = ga_module,
            },
            .{
                .name = "parse",
                .module = parse_module,
            },
            .{
                .name = "flavours",
                .module = flavours_module,
            },
            .{
                .name = "geometry",
                .module = geometry_module,
            },
            .{
                .name = "render",
                .module = render_module,
            },
        },
    });

    const demo_core_debug = b.createModule(.{
        .root_source_file = b.path("src/demos/core.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{.{
            .name = "zmath",
            .module = zmath,
        }},
    });

    const demo_euclidean_sdf_module = b.createModule(.{
        .root_source_file = b.path("src/demos/euclidean_sdf.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{
            .name = "zmath",
            .module = zmath,
        }},
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

    const spirv_steps = build_spirv.addSpirvSteps(b, optimize, use_llvm_spirv, compare_spirv);

    const vulkan_glfw_translate = b.addTranslateC(.{
        .root_source_file = b.path("tools/vulkan_glfw.h"),
        .target = target,
        .optimize = optimize,
    });
    addEnvIncludePaths(b, vulkan_glfw_translate, "C_INCLUDE_PATH");
    addEnvIncludePaths(b, vulkan_glfw_translate, "CPATH");
    const vulkan_glfw_module = vulkan_glfw_translate.createModule();

    const shader_playground_exe = b.addExecutable(.{
        .name = "zmath-shader-playground",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/shader_playground.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{
                .name = "vulkan_glfw",
                .module = vulkan_glfw_module,
            }},
        }),
    });
    shader_playground_exe.root_module.linkSystemLibrary("glfw", .{});
    shader_playground_exe.root_module.linkSystemLibrary("vulkan", .{});

    const shader_playground_build_step = b.step("shader-playground-build", "Build the Vulkan SPIR-V shader playground");
    shader_playground_build_step.dependOn(&shader_playground_exe.step);

    const run_shader_playground = b.addRunArtifact(shader_playground_exe);
    run_shader_playground.step.dependOn(spirv_steps.raw);
    const shader_playground_step = b.step("shader-playground", "Run the Vulkan SPIR-V shader playground with driver-valid raw shaders");
    shader_playground_step.dependOn(&run_shader_playground.step);
    if (b.args) |args| {
        run_shader_playground.addArgs(args);
    }

    const run_shader_playground_ga = b.addRunArtifact(shader_playground_exe);
    run_shader_playground_ga.step.dependOn(spirv_steps.vga);
    run_shader_playground_ga.addArgs(&.{
        "zig-out/shaders/vga_passthrough.vert.spv",
        "zig-out/shaders/vga_passthrough.frag.spv",
    });
    const shader_playground_ga_step = b.step("shader-playground-ga", "Run the Vulkan SPIR-V shader playground with GA shaders; currently useful for driver/compiler debugging");
    shader_playground_ga_step.dependOn(&run_shader_playground_ga.step);

    const ga_tests = b.addTest(.{
        .name = "ga-module",
        .root_module = ga_module,
    });
    const run_ga_tests = b.addRunArtifact(ga_tests);
    run_ga_tests.setName("run test ga-module");

    const parse_tests = b.addTest(.{
        .name = "parse-module",
        .root_module = parse_module,
    });
    const run_parse_tests = b.addRunArtifact(parse_tests);
    run_parse_tests.setName("run test parse-module");

    const flavours_tests = b.addTest(.{
        .name = "flavours-module",
        .root_module = flavours_module,
    });
    const run_flavours_tests = b.addRunArtifact(flavours_tests);
    run_flavours_tests.setName("run test flavours-module");

    const geometry_tests = b.addTest(.{
        .name = "geometry-module",
        .root_module = geometry_module,
    });
    const run_geometry_tests = b.addRunArtifact(geometry_tests);
    run_geometry_tests.setName("run test geometry-module");

    const render_tests = b.addTest(.{
        .name = "render-module",
        .root_module = render_module,
    });
    const run_render_tests = b.addRunArtifact(render_tests);
    run_render_tests.setName("run test render-module");

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
                    .module = demo_core_debug,
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
                    .module = demo_core_debug,
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
                    .module = demo_core_debug,
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
                    .module = demo_core_debug,
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
                    .module = demo_core_debug,
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
                    .module = demo_core_debug,
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
                    .module = demo_core_debug,
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
                    .module = demo_euclidean_sdf_module,
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

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
        .linkage = .dynamic,
        .raudio = false,
        .rmodels = false,
        .linux_display_backend = .X11,
    });
    const raylib = raylib_dep.artifact("raylib");
    const raylib_module = raylib_dep.module("raylib");
    const raylib_demo_story_module = b.createModule(.{
        .root_source_file = b.path("src/demos/raylib_demo/story.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{
            .{
                .name = "zmath",
                .module = zmath,
            },
            .{
                .name = "raylib",
                .module = raylib_module,
            },
        },
    });

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
                    .name = "raylib",
                    .module = raylib_module,
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
    const raylib_demo_alias_step = b.step("raylib-demo", "Alias for demo-raylib");
    raylib_demo_alias_step.dependOn(&demo_raylib_run_cmd.step);

    const profile_raylib_spherical_cube_exe = b.addExecutable(.{
        .name = "zmath-profile-raylib-spherical-cube",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/profile/raylib_spherical_cube_probe.zig"),
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
            .imports = &.{
                .{
                    .name = "zmath",
                    .module = zmath,
                },
                .{
                    .name = "raylib",
                    .module = raylib_module,
                },
                .{
                    .name = "raylib_demo_story",
                    .module = raylib_demo_story_module,
                },
            },
        }),
    });
    profile_raylib_spherical_cube_exe.root_module.linkLibrary(raylib);

    const profile_raylib_spherical_cube_step = b.step(
        "profile-raylib-spherical-cube",
        "Dump CPU-side raylib spherical cube projection pathologies",
    );
    const run_profile_raylib_spherical_cube = b.addRunArtifact(profile_raylib_spherical_cube_exe);
    profile_raylib_spherical_cube_step.dependOn(&run_profile_raylib_spherical_cube.step);

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

    const compile_fail_hodge_dual = b.addObject(.{
        .name = "zmath-compile-fail-hodge-dual-degenerate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/compile_fail/hodge_dual_degenerate.zig"),
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
    compile_fail_hodge_dual.expect_errors = .{
        .contains = "complement duality",
    };

    const compile_fail_step = b.step("compile-fail", "Run expected compile-fail checks");
    compile_fail_step.dependOn(&compile_fail_hodge_dual.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_ga_tests.step);
    test_step.dependOn(&run_parse_tests.step);
    test_step.dependOn(&run_flavours_tests.step);
    test_step.dependOn(&run_geometry_tests.step);
    test_step.dependOn(&run_render_tests.step);
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_module_surface_tests.step);
    test_step.dependOn(&run_demo_core_tests.step);
    test_step.dependOn(compile_fail_step);

    const fuzz_expr_step = b.step("fuzz-expr", "Run the expression parser/evaluator fuzz smoke test");
    fuzz_expr_step.dependOn(&run_expression_fuzz.step);
}

fn addEnvIncludePaths(b: *std.Build, translate_c: *std.Build.Step.TranslateC, name: []const u8) void {
    const value = b.graph.environ_map.get(name) orelse return;
    var it = std.mem.splitScalar(u8, value, ':');
    while (it.next()) |path| {
        if (path.len == 0) continue;
        translate_c.addSystemIncludePath(.{ .cwd_relative = path });
    }
}

fn addEnvIncludePaths(b: *std.Build, translate_c: *std.Build.Step.TranslateC, name: []const u8) void {
    const value = b.graph.environ_map.get(name) orelse return;
    var it = std.mem.splitScalar(u8, value, ':');
    while (it.next()) |path| {
        if (path.len == 0) continue;
        translate_c.addSystemIncludePath(.{ .cwd_relative = path });
    }
}
