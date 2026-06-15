const std = @import("std");
const build_spirv = @import("build_spirv.zig");

const Modules = struct {
    meta: *std.Build.Module,
    parse: *std.Build.Module,
    ga: *std.Build.Module,
    flavours: *std.Build.Module,
    geometry: *std.Build.Module,
    render: *std.Build.Module,
    zmath: *std.Build.Module,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const fuzz_use_llvm = b.option(bool, "fuzz-llvm", "Force LLVM backend for fuzz test builds") orelse true;
    const use_llvm_spirv = b.option(bool, "llvm-spirv", "Use LLVM backend for SPIR-V shader builds") orelse false;
    const compare_spirv = b.option(bool, "compare-spirv", "Emit SPIR-V size comparison for GA vs raw shader variants") orelse false;

    const modules = addModules(b, target);

    const example = b.addExecutable(.{
        .name = "zmath",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zmath", .module = modules.zmath }},
        }),
    });

    const run_step = b.step("run", "Run the usage example");
    const run_cmd = b.addRunArtifact(example);
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| run_cmd.addArgs(args);

    const demo = b.addExecutable(.{
        .name = "zmath-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demos/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zmath", .module = modules.zmath }},
        }),
    });

    const demo_step = b.step("demo", "Run the terminal demo");
    const demo_cmd = b.addRunArtifact(demo);
    demo_step.dependOn(&demo_cmd.step);
    if (b.args) |args| demo_cmd.addArgs(args);

    const bench = b.addExecutable(.{
        .name = "zmath-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "zmath", .module = modules.zmath }},
        }),
    });

    const bench_step = b.step("bench-simd", "Run SIMD micro-benchmarks (ReleaseFast)");
    bench_step.dependOn(&b.addRunArtifact(bench).step);

    addLocalVulkanPlaygroundSteps(b, target, optimize, use_llvm_spirv, compare_spirv);
    addTests(b, target, optimize, modules, example, fuzz_use_llvm);
}

fn addModules(b: *std.Build, target: std.Build.ResolvedTarget) Modules {
    const meta = b.addModule("meta", .{
        .root_source_file = b.path("src/meta.zig"),
        .target = target,
    });

    const parse = b.addModule("parse", .{
        .root_source_file = b.path("src/parse.zig"),
        .target = target,
        .imports = &.{.{ .name = "meta", .module = meta }},
    });

    const ga = b.addModule("ga", .{
        .root_source_file = b.path("src/ga.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "meta", .module = meta },
            .{ .name = "parse", .module = parse },
        },
    });
    ga.addImport("ga", ga);

    const flavours = b.addModule("flavours", .{
        .root_source_file = b.path("src/flavours.zig"),
        .target = target,
        .imports = &.{.{ .name = "ga", .module = ga }},
    });

    const geometry = b.addModule("geometry", .{
        .root_source_file = b.path("src/geometry.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "ga", .module = ga },
            .{ .name = "flavours", .module = flavours },
        },
    });

    const render = b.addModule("render", .{
        .root_source_file = b.path("src/render.zig"),
        .target = target,
        .imports = &.{.{ .name = "ga", .module = ga }},
    });
    geometry.addImport("render", render);
    render.addImport("geometry", geometry);

    const zmath = b.addModule("zmath", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "ga", .module = ga },
            .{ .name = "parse", .module = parse },
            .{ .name = "flavours", .module = flavours },
            .{ .name = "geometry", .module = geometry },
            .{ .name = "render", .module = render },
        },
    });

    return .{
        .meta = meta,
        .parse = parse,
        .ga = ga,
        .flavours = flavours,
        .geometry = geometry,
        .render = render,
        .zmath = zmath,
    };
}

fn addLocalVulkanPlaygroundSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_llvm_spirv: bool,
    compare_spirv: bool,
) void {
    const spirv_steps = build_spirv.addSpirvSteps(b, optimize, use_llvm_spirv, compare_spirv);

    const vulkan_glfw_translate = b.addTranslateC(.{
        .root_source_file = b.path("tools/vulkan_glfw.h"),
        .target = target,
        .optimize = optimize,
    });
    addEnvIncludePaths(b, vulkan_glfw_translate, "C_INCLUDE_PATH");
    addEnvIncludePaths(b, vulkan_glfw_translate, "CPATH");

    const shader_playground_exe = b.addExecutable(.{
        .name = "zmath-shader-playground",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/shader_playground.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{
                .name = "vulkan_glfw",
                .module = vulkan_glfw_translate.createModule(),
            }},
        }),
    });
    shader_playground_exe.root_module.linkSystemLibrary("glfw", .{});
    shader_playground_exe.root_module.linkSystemLibrary("vulkan", .{});

    const build_step = b.step("shader-playground-build", "Build the Vulkan SPIR-V shader playground");
    build_step.dependOn(&shader_playground_exe.step);

    const run_raw = b.addRunArtifact(shader_playground_exe);
    run_raw.step.dependOn(spirv_steps.raw);
    const raw_step = b.step("shader-playground", "Run the Vulkan SPIR-V shader playground with raw shaders");
    raw_step.dependOn(&run_raw.step);
    if (b.args) |args| run_raw.addArgs(args);

    const run_ga = b.addRunArtifact(shader_playground_exe);
    run_ga.step.dependOn(spirv_steps.vga);
    run_ga.addArgs(&.{
        "zig-out/shaders/vga_passthrough.vert.spv",
        "zig-out/shaders/vga_passthrough.frag.spv",
    });
    const ga_step = b.step("shader-playground-ga", "Run the Vulkan SPIR-V shader playground with GA shaders");
    ga_step.dependOn(&run_ga.step);
}

fn addTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: Modules,
    example: *std.Build.Step.Compile,
    fuzz_use_llvm: bool,
) void {
    const test_step = b.step("test", "Run tests");

    inline for (.{
        .{ "ga-module", modules.ga },
        .{ "parse-module", modules.parse },
        .{ "flavours-module", modules.flavours },
        .{ "geometry-module", modules.geometry },
        .{ "render-module", modules.render },
        .{ "zmath-module", modules.zmath },
    }) |entry| {
        const tests = b.addTest(.{ .name = entry[0], .root_module = entry[1] });
        const run = b.addRunArtifact(tests);
        run.setName("run test " ++ entry[0]);
        test_step.dependOn(&run.step);
    }

    const example_tests = b.addTest(.{ .name = "zmath-cli", .root_module = example.root_module });
    test_step.dependOn(&b.addRunArtifact(example_tests).step);

    const module_surface_tests = b.addTest(.{
        .name = "zmath-module-surfaces",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/tests/modules.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zmath", .module = modules.zmath }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(module_surface_tests).step);

    const demo_core_tests = b.addTest(.{
        .name = "zmath-demo-core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demos/core.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zmath", .module = modules.zmath }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(demo_core_tests).step);

    const compile_fail_hodge_dual = b.addObject(.{
        .name = "zmath-compile-fail-hodge-dual-degenerate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/compile_fail/hodge_dual_degenerate.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zmath", .module = modules.zmath }},
        }),
    });
    compile_fail_hodge_dual.expect_errors = .{ .contains = "complement duality" };
    test_step.dependOn(&compile_fail_hodge_dual.step);

    const expression_fuzz_tests = b.addTest(.{
        .name = "zmath-expression-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fuzz/expression.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zmath", .module = modules.zmath }},
        }),
        .use_llvm = fuzz_use_llvm,
    });

    const fuzz_step = b.step("fuzz-expr", "Run the expression parser/evaluator fuzz smoke test");
    fuzz_step.dependOn(&b.addRunArtifact(expression_fuzz_tests).step);
}

fn addEnvIncludePaths(b: *std.Build, translate_c: *std.Build.Step.TranslateC, name: []const u8) void {
    const value = b.graph.environ_map.get(name) orelse return;
    var it = std.mem.splitScalar(u8, value, ':');
    while (it.next()) |path| {
        if (path.len == 0) continue;
        translate_c.addSystemIncludePath(.{ .cwd_relative = path });
    }
}
