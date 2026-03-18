const std = @import("std");

fn pathLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn addGaLeafTests(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
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
            }),
        });
        const run_leaf_tests = b.addRunArtifact(leaf_tests);
        test_step.dependOn(&run_leaf_tests.step);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    addGaLeafTests(b, test_step, target, optimize) catch |err| {
        std.debug.panic("failed to configure GA leaf tests: {s}", .{@errorName(err)});
    };

    test_step.dependOn(&run_exe_tests.step);
}
