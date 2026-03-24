const std = @import("std");
const zmath = @import("zmath");
const ga = zmath.ga;
const Cl3 = ga.Algebra(.euclidean(3));

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const masks = ga.gradeBladeMasks(4, 1);
    try stdout.writeAll("gradeBladeMasks(4, 1): [");
    for (masks, 0..) |mask, index| {
        if (index != 0) try stdout.writeAll(", ");
        try ga.writeBladeMask(stdout, mask, 4);
    }
    try stdout.writeAll("]\n");

    const Vec3 = Cl3.Vector(f64);
    const E3 = Cl3.Basis(f64);
    const v = Vec3.init(.{ 1.0, 2.0, 3.0 });
    const e2 = E3.e(2);
    const e12 = E3.signedBlade("e12");

    try stdout.print("Vec3: {f}\n", .{v});
    try stdout.print("E3.e(2): {f}\n", .{e2});
    try stdout.print("E3.signedBlade(\"e12\"): {f}\n", .{e12});
    try stdout.print("choose(3, 2): {}\n", .{ga.choose(3, 2)});
    try stdout.flush();
}

test "example wiring compiles" {
    const Vec3 = Cl3.Vector(f64);
    const v = Vec3.init(.{ 1.0, 2.0, 3.0 });
    try std.testing.expectEqual(@as(f64, 3.0), v.coeff(ga.BladeMask.parseForDimensionPanicking("e3", Cl3.dimension)));
    try std.testing.expect(Cl3.Basis(f64).signedBlade("e21").eql(Cl3.Bivector(f64).init(.{ -1, 0, 0 })));
}
