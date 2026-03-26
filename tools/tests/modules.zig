const std = @import("std");
const zmath = @import("zmath");

const curved = zmath.geometry.constant_curvature;
const projection = zmath.render.projection;

test "import geometry and render test modules" {
    _ = curved;
    _ = projection;
    try std.testing.expect(true);
}
