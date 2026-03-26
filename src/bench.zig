const std = @import("std");
const bench_main = @import("bench_main.zig");

pub fn main(init: std.process.Init) !void {
    try bench_main.run(init, "simd");
}
