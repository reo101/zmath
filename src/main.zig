const std = @import("std");
const zmath = @import("zmath");
const ga = zmath.ga;
const Cl3 = ga.Algebra(.euclidean(3));

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const Vec3 = Cl3.Vector(f64);
    const E3 = Cl3.Basis(f64);
    const v = Vec3.init(.{ 1.0, 2.0, 3.0 });
    const e1 = E3.e(1);
    const e2 = E3.e(2);
    const e12 = E3.signedBlade("e12");

    try stdout.print("Vec3: {f}\n", .{v});
    try stdout.print("E3.e(1): {f}\n", .{e1});
    try stdout.print("E3.e(2): {f}\n", .{e2});
    try stdout.print("E3.signedBlade(\"e12\"): {f}\n", .{e12});
    try stdout.print("v ^ e1: {f}\n", .{v.wedge(e1)});
    try stdout.flush();
}

test "example wiring compiles" {
    const Vec3 = Cl3.Vector(f64);
    const v = Vec3.init(.{ 1.0, 2.0, 3.0 });
    try std.testing.expectEqual(@as(f64, 3.0), v.coeffNamed("e3"));
    try std.testing.expect(Cl3.Basis(f64).signedBlade("e21").eql(Cl3.Bivector(f64).init(.{ -1, 0, 0 })));
}
