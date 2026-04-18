//! zmath: Canonical Library Usage Example
//!
//! This example demonstrates the high-level API for creating algebras,
//! working with multivectors, and using the comptime expression compiler.

const std = @import("std");
const zmath = @import("root.zig");
const ga = zmath.ga;

/// Define a 3D Euclidean Algebra bound to f64 coefficients.
const Cl3 = ga.Algebra(.euclidean(3)).Instantiate(f64);

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    // 1. Traditional Constructor API
    // -------------------------------------------------------------------------
    const v = Cl3.Vector.init(.{ 1.0, 2.0, 3.0 });
    const e1 = Cl3.Basis.e(1);
    const e2 = Cl3.Basis.e(2);

    try stdout.print("Vector v: {any}\n", .{v.named()});
    try stdout.print("Basis e1: {any}\n", .{e1.named()});

    // 2. Comptime Expression Compiler
    // -------------------------------------------------------------------------
    // The `expr` function compiles the string at comptime into optimal Zig code.
    // It verifies operator precedence and resource bounds before execution.
    const result = Cl3.expr("{v} ^ e12 + 5", .{
        .v = v,
    });

    try stdout.print("Expression ({{v}} ^ e12 + 5): {any}\n", .{result.coeffsArray()});

    // 3. Geometric Operations
    // -------------------------------------------------------------------------
    // Reflect vector 'v' across the plane defined by its normal 'e2'.
    // In GA, reflection is -n * v * n
    const reflected = Cl3.expr("-{n} * {v} * {n}", .{
        .n = e2,
        .v = v,
    });

    try stdout.print("v reflected across e2: {any}\n", .{reflected.gradePart(1).named()});

    // 4. Proactive Validation
    // -------------------------------------------------------------------------
    // All signatures and operations are checked for consistency.
    // Invalid basis names or dimensions mismatches result in compile errors.
    const e123 = Cl3.signedBlade("e123");
    try stdout.print("Pseudoscalar e123: {any}\n", .{e123.named()});

    // CGA Naming Demo
    const cga = zmath.flavours.cga;
    const p = cga.Point.init(1, 2, 3);
    try stdout.writeAll("\nCGA Naming Demo:\n");
    try stdout.print("  Point p (struct): {any}\n", .{p.named()});
    try stdout.print("  Point p (string): {f}\n", .{p});

    try stdout.flush();
}

test "canonical example logic" {
    const v = Cl3.Vector.init(.{ 1.0, 2.0, 3.0 });
    const e2 = Cl3.Basis.e(2);
    
    // Manual reflection check
    const reflected = e2.gp(v).gp(e2).negate().gradePart(1);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), reflected.named().e1, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, -2.0), reflected.named().e2, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), reflected.named().e3, 1e-10);
}
