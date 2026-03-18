const std = @import("std");
const zmath = @import("zmath");
const ga = zmath.ga;

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

    const Vec3 = ga.GAVector(f64, 3);
    const E3 = ga.Basis(f64, 3);
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
    const Vec3 = ga.GAVector(f64, 3);
    const v = Vec3.init(.{ 1.0, 2.0, 3.0 });
    try std.testing.expectEqual(@as(f64, 3.0), v.coeff(0b100));
    try std.testing.expect(ga.Basis(f64, 3).signedBlade("e21").eql(ga.Bivector(f64, 3).init(.{ -1, 0, 0 })));
}
