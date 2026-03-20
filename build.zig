const std = @import("std");

fn pathLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn addGaLeafTests(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options_module: *std.Build.Module,
) !void {
    var ga_dir = try b.build_root.handle.openDir(b.graph.io, "src/ga", .{ .iterate = true });
    defer ga_dir.close(b.graph.io);

    var walker = try ga_dir.walk(b.allocator);
    defer walker.deinit();

    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(b.allocator);

    while (try walker.next(b.graph.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const root_path = try std.fmt.allocPrint(b.allocator, "src/ga/{s}", .{entry.path});
        try roots.append(b.allocator, root_path);
    }

    std.mem.sort([]const u8, roots.items, {}, pathLessThan);

    for (roots.items) |root_path| {
        const leaf_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(root_path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{
                        .name = "build_options",
                        .module = build_options_module,
                    },
                },
            }),
        });
        const run_leaf_tests = b.addRunArtifact(leaf_tests);
        test_step.dependOn(&run_leaf_tests.step);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const zmath_tests = b.addTest(.{
        .root_module = zmath,
    });

    const run_mod_tests = b.addRunArtifact(zmath_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    addGaLeafTests(b, test_step, target, optimize, simd_build_options_module) catch |err| {
        std.debug.panic("failed to configure GA leaf tests: {s}", .{@errorName(err)});
    };

    test_step.dependOn(&run_exe_tests.step);
}
