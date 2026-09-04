//! Property-based law checks for the GA core and the RGA surface.
//!
//! Two layers:
//! - Plain seeded tests run on every `zig build test` (deterministic PRNG,
//!   hundreds of iterations per law).
//! - A `std.testing.fuzz` callback over structured `Smith` inputs, so
//!   `zig build test fuzz-ga --fuzz` runs the same laws continuously with
//!   coverage guidance (in plain test mode the callback runs once).
//!
//! Zig has no proptest/quickcheck equivalent; the idiom is exactly this:
//! seeded loops in tests plus the built-in fuzz runner for continuous mode.
const std = @import("std");
const ga = @import("zmath").ga;
const rga = ga.rga;
const rotors = ga.rotors;
const multivector = ga.multivector;

fn randomScalar(rand: std.Random) f64 {
    return 2.0 * rand.float(f64) - 1.0;
}

fn randomVector(comptime NS: type, rand: std.Random) NS.Vector {
    var coeffs: [NS.Vector.dimensions]f64 = undefined;
    for (&coeffs) |*c| c.* = randomScalar(rand);
    return NS.Vector.init(coeffs);
}

fn randomFull(comptime NS: type, rand: std.Random) NS.Full {
    var coeffs: [NS.Full.stored_blade_count]f64 = undefined;
    for (&coeffs) |*c| c.* = randomScalar(rand);
    return NS.Full.init(coeffs);
}

fn expectNear(a: anytype, b: anytype, tolerance: f64) !void {
    const Full = multivector.FullMultivector(f64, @TypeOf(a).metric_signature);
    const fa = a.cast(Full);
    const fb = b.cast(Full);
    inline for (0..Full.stored_blade_count) |i| {
        try std.testing.expectApproxEqAbs(@as(f64, 0), fa.coeffsArray()[i] - fb.coeffsArray()[i], tolerance);
    }
}

fn expectNearZero(mv: anytype, tolerance: f64) !void {
    const Full = multivector.FullMultivector(f64, @TypeOf(mv).metric_signature);
    const f = mv.cast(Full);
    inline for (0..Full.stored_blade_count) |i| {
        try std.testing.expectApproxEqAbs(@as(f64, 0), f.coeffsArray()[i], tolerance);
    }
}

fn pseudoscalar(comptime NS: type) NS.Full {
    var coeffs: [NS.Full.stored_blade_count]f64 = undefined;
    for (&coeffs) |*c| c.* = 0;
    coeffs[NS.Full.stored_blade_count - 1] = 1;
    return NS.Full.init(coeffs);
}

/// wedge anticommutativity: a ^ b = -(b ^ a)
fn checkWedgeAnticommutativity(comptime NS: type, rand: std.Random) !void {
    const a = randomVector(NS, rand);
    const b = randomVector(NS, rand);
    const sum = a.wedge(b).add(b.wedge(a));
    try expectNearZero(sum, 1e-9);
}

/// geometric product associativity on vectors: (a b) c = a (b c)
fn checkGpAssociativity(comptime NS: type, rand: std.Random) !void {
    const a = randomVector(NS, rand);
    const b = randomVector(NS, rand);
    const c = randomVector(NS, rand);
    try expectNear(a.gp(b).gp(c), a.gp(b.gp(c)), 1e-8);
}

/// reverse anti-automorphism: ~(x y) = y~ x~
fn checkReverseAntiAutomorphism(comptime NS: type, rand: std.Random) !void {
    const x = randomFull(NS, rand);
    const y = randomFull(NS, rand);
    try expectNear(x.gp(y).reverse(), y.reverse().gp(x.reverse()), 1e-7);
}

/// scalar product symmetry: <x, y> = <y, x>
fn checkScalarProductSymmetry(comptime NS: type, rand: std.Random) !void {
    const x = randomFull(NS, rand);
    const y = randomFull(NS, rand);
    try std.testing.expectApproxEqAbs(
        x.scalarProduct(y),
        y.scalarProduct(x),
        1e-8,
    );
}

/// versor sandwich preserves the metric form: (R v R~)~ (R v R~) = v~ v
/// for versors built from unit vectors.
fn checkVersorSandwichPreservesNorm(comptime NS: type, rand: std.Random) !void {
    const v1 = normalizedAwayFromNull(randomVector(NS, rand));
    const v2 = normalizedAwayFromNull(randomVector(NS, rand));
    const rotor = v1.gp(v2);
    const v = randomVector(NS, rand);
    const turned = v.sandwich(rotor);
    try std.testing.expectApproxEqAbs(
        v.scalarNormSquared(),
        turned.scalarNormSquared(),
        1e-7 * @max(1.0, @abs(v.scalarNormSquared())),
    );
}

fn normalizedAwayFromNull(v: anytype) @TypeOf(v) {
    var candidate = v;
    if (@abs(candidate.scalarNormSquared()) < 0.5) {
        // Nudge onto a safely non-null direction along the first axis.
        var coeffs = v.coeffsArray();
        coeffs[0] = 2.0;
        candidate = @TypeOf(v).init(coeffs);
    }
    return candidate.scale(1.0 / @sqrt(@abs(candidate.scalarNormSquared())));
}

/// Hodge dual defining property: A ^ hodgeDual(A) = (A, A) * I
fn checkHodgeDefiningProperty(comptime NS: type, rand: std.Random) !void {
    const v = randomVector(NS, rand);
    const lhs = v.wedge(v.hodgeDual()).cast(NS.Full);
    const rhs = v.scalarProduct(v);
    try expectNear(lhs, pseudoscalar(NS).scale(rhs), 1e-8);
}

/// Hodge dual involution on vectors: dual(dual(v)) = (det g) * (-1)^(n-1) v
fn checkHodgeVectorInvolution(comptime NS: type, comptime expected_sign: f64, rand: std.Random) !void {
    const v = randomVector(NS, rand);
    const twice = v.hodgeDual().hodgeDual().cast(NS.Vector);
    try expectNear(twice, v.scale(expected_sign), 1e-8);
}

/// join consistency: A join B = complementDual(complementDual(A) ^ complementDual(B))
fn checkJoinConsistency(comptime NS: type, rand: std.Random) !void {
    const a = randomVector(NS, rand);
    const b = randomVector(NS, rand);
    const via_join = a.join(b);
    const manual = a.complementDual().wedge(b.complementDual()).complementDual();
    try expectNear(via_join, manual, 1e-8);
}

/// RGA bulk contraction on same-grade vectors equals the scalar part of
/// the reversed product up to the intrinsic double-complement sign
/// (−1)^(n−1) for vectors: a v b-star = (−1)^(n−1) <b~ a>_0. Anchored in
/// Euclidean metrics; indefinite signatures diverge beyond a sign (the
/// timelike contributions carry opposite metric signs, which is exactly
/// the bulk/weight distinction, e.g. in Cl(3,1) bulkContraction(e4, e4)
/// = +1 while the metric dot is −1).
fn checkRgaBulkContraction(comptime NS: type, rand: std.Random) !void {
    const double_complement_sign: f64 = if (@mod(NS.Vector.dimensions, 2) == 0) -1.0 else 1.0;
    const a = randomVector(NS, rand);
    const b = randomVector(NS, rand);
    const contracted = rga.bulkContraction(a, b);
    const grade_part = b.reverse().gp(a).gradePart(0);
    try expectNear(contracted, grade_part.scale(double_complement_sign), 1e-8);
}

/// RGA same-grade bulk expansion equals the scalar product lifted to the
/// pseudoscalar (Euclidean metrics only; mixed metrics differ by metric
/// signs in the dual).
fn checkRgaBulkExpansionScalarLift(comptime NS: type, rand: std.Random) !void {
    const a = randomVector(NS, rand);
    const b = randomVector(NS, rand);
    const expanded = rga.bulkExpansion(a, b).cast(NS.Full);
    const lifted = a.dot(b).cast(NS.Full).gp(pseudoscalar(NS));
    try expectNear(expanded, lifted, 1e-8);
}

/// RGA bulk dual is nilpotent in the degenerate projective algebra
/// (det g = 0 implies u** == 0).
fn checkRgaBulkDualNilpotent(comptime NS: type, rand: std.Random) !void {
    const x = randomFull(NS, rand);
    try expectNearZero(rga.bulkDual(rga.bulkDual(x)), 1e-7);
}

/// rotorFromTo followed by the sandwich lands on the target (2D VGA).
fn checkRotorFromToRoundtrip(rand: std.Random) !void {
    const E2 = ga.Algebra(.euclidean(2)).Instantiate(f64);
    var from = randomVector(E2, rand);
    var to = randomVector(E2, rand);
    // Avoid degenerate samples where the 2D rotor is ambiguous.
    if (from.scalarNormSquared() < 1e-6) from = E2.Vector.init(.{ 1, 0 });
    if (to.scalarNormSquared() < 1e-6) to = E2.Vector.init(.{ 0, 1 });
    var from_unit = from.scale(1.0 / @sqrt(from.scalarNormSquared()));
    var to_unit = to.scale(1.0 / @sqrt(to.scalarNormSquared()));
    // Avoid near-antipodal pairs where the 2D rotor is ambiguous.
    if (from_unit.add(to_unit).scalarNormSquared() < 1e-3) to_unit = to_unit.negate();

    const rotor = rotors.rotorFromTo(from_unit, to_unit);
    try expectNear(rotors.rotated(from_unit, rotor), to_unit, 1e-7);
}

test "ga algebra laws over seeded random samples" {
    var prng = std.Random.DefaultPrng.init(0x5EED_0001);
    const rand = prng.random();

    const Euclid3 = ga.Algebra(.euclidean(3)).Instantiate(f64);
    const Euclid4 = ga.Algebra(.euclidean(4)).Instantiate(f64);
    const Lorentz31 = ga.Algebra(.{ .p = 3, .q = 1 }).Instantiate(f64);
    const Rigid301 = ga.Algebra(.{ .p = 3, .q = 0, .r = 1 }).Instantiate(f64);

    var iteration: usize = 0;
    while (iteration < 256) : (iteration += 1) {
        try checkWedgeAnticommutativity(Euclid3, rand);
        try checkWedgeAnticommutativity(Lorentz31, rand);
        try checkWedgeAnticommutativity(Rigid301, rand);
        try checkGpAssociativity(Euclid3, rand);
        try checkGpAssociativity(Lorentz31, rand);
        try checkReverseAntiAutomorphism(Euclid4, rand);
        try checkReverseAntiAutomorphism(Lorentz31, rand);
        try checkScalarProductSymmetry(Lorentz31, rand);
        try checkVersorSandwichPreservesNorm(Euclid3, rand);
        try checkVersorSandwichPreservesNorm(Lorentz31, rand);
        try checkHodgeDefiningProperty(Euclid3, rand);
        try checkHodgeDefiningProperty(Lorentz31, rand);
        // det(euclidean(3)) = +1: dual(dual(v)) = (+1)(-1)^(3-1) v = +v.
        try checkHodgeVectorInvolution(Euclid3, 1.0, rand);
        // det(euclidean(4)) = +1: dual(dual(v)) = (+1)(-1)^(4-1) v = -v.
        try checkHodgeVectorInvolution(Euclid4, -1.0, rand);
        // det(diag(1,1,1,-1)) = -1: dual(dual(v)) = (-1)(-1)^(4-1) v = +v.
        try checkHodgeVectorInvolution(Lorentz31, 1.0, rand);
        try checkJoinConsistency(Euclid3, rand);
        try checkJoinConsistency(Lorentz31, rand);
        try checkJoinConsistency(Rigid301, rand);
        try checkRgaBulkContraction(Euclid3, rand);
        try checkRgaBulkContraction(Euclid4, rand);
        try checkRgaBulkExpansionScalarLift(Euclid3, rand);
        try checkRgaBulkDualNilpotent(Rigid301, rand);
        try checkRotorFromToRoundtrip(rand);
    }
}

test "ga laws fuzz target" {
    try std.testing.fuzz({}, struct {
        fn smithVector(comptime NS: type, smith: *std.testing.Smith) NS.Vector {
            var coeffs: [NS.Vector.dimensions]f64 = undefined;
            for (&coeffs) |*c| {
                c.* = @as(f64, @floatFromInt(smith.value(i8))) / 8.0;
            }
            return NS.Vector.init(coeffs);
        }

        fn smithFull(comptime NS: type, smith: *std.testing.Smith) NS.Full {
            var coeffs: [NS.Full.stored_blade_count]f64 = undefined;
            for (&coeffs) |*c| {
                c.* = @as(f64, @floatFromInt(smith.value(i8))) / 8.0;
            }
            return NS.Full.init(coeffs);
        }

        fn checkOne(_: void, smith: *std.testing.Smith) anyerror!void {
            const Euclid3 = ga.Algebra(.euclidean(3)).Instantiate(f64);
            const Lorentz31 = ga.Algebra(.{ .p = 3, .q = 1 }).Instantiate(f64);
            const Rigid301 = ga.Algebra(.{ .p = 3, .q = 0, .r = 1 }).Instantiate(f64);

            const a3 = smithVector(Euclid3, smith);
            const b3 = smithVector(Euclid3, smith);
            try expectNearZero(a3.wedge(b3).add(b3.wedge(a3)), 1e-7);
            var prng3 = std.Random.DefaultPrng.init(smith.value(u32));
            try checkRgaBulkContraction(Euclid3, prng3.random());

            const al = smithVector(Lorentz31, smith);
            const bl = smithVector(Lorentz31, smith);
            try expectNearZero(al.wedge(bl).add(bl.wedge(al)), 1e-7);
            var prngl = std.Random.DefaultPrng.init(smith.value(u32));
            try checkJoinConsistency(Lorentz31, prngl.random());

            const xr = smithFull(Rigid301, smith);
            try expectNearZero(rga.bulkDual(rga.bulkDual(xr)), 1e-5);
        }
    }.checkOne, .{});
}
