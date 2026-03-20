const std = @import("std");
const build_options = @import("build_options");
const bench_main = @import("bench_main.zig");

pub fn main(init: std.process.Init) !void {
    comptime {
        if (!build_options.enable_simd_fast_paths) {
            @compileError("bench.zig expects SIMD fast paths to be enabled via build options");
        }
    }
    try bench_main.run(init, "simd");
}
