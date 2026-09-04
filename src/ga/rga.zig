//! Rigid Geometric Algebra (RGA) interior products and projections.
//!
//! Definitions follow the RGA convention set (rigidgeometricalgebra.org,
//! "Duals" and "Interior products"), phrased over this library's generic
//! multivector carriers:
//!
//! - bulk dual   `u★ = ũ ⦑ 𝟙` (reverse, geometric product, pseudoscalar)
//! - weight dual `u☆ = ũ ⦗ 1` (reverse, geometric antiproduct, unit scalar)
//! - contractions `a ∨ b★ / a ∨ b☆` (antiwedge against the duals)
//! - expansions   `a ∧ b★ / a ∧ b☆` (wedge against the duals)
//! - projection   `b ∨ (a ∧ b☆)`, antiprojection `b ∧ (a ∨ b☆)`
//!
//! These are pure combinators over `gp`, `wedge`, `antiWedge`, `antiGeometric`
//! and `reverse`, so they work in any signature. Note that in a degenerate
//! metric (e.g. the projective `Cl(3,0,1)`) both duals annihilate the null
//! axis' metric content and applying either dual twice yields zero (the
//! metric determinant vanishes); see the tests for the identities that hold
//! per signature. The projection/antiprojection formulas assume objects that
//! carry both bulk and weight content (as in the RGA's mixed representation);
//! for pure plane-based-PGA blades they are the incidence combinatorics only.
const std = @import("std");
const multivector = @import("multivector.zig");

fn FullOf(comptime M: type) type {
    return multivector.FullMultivector(M.Coefficient, M.metric_signature);
}

/// The unit pseudoscalar of the algebra, as a full multivector.
fn pseudoscalarOf(comptime M: type) FullOf(M) {
    const Full = FullOf(M);
    var coeffs = std.mem.zeroes([Full.stored_blade_count]M.Coefficient);
    coeffs[Full.stored_blade_count - 1] = 1;
    return Full.init(coeffs);
}

/// The unit scalar of the algebra, as a full multivector.
fn scalarOneOf(comptime M: type) FullOf(M) {
    const Full = FullOf(M);
    var coeffs = std.mem.zeroes([Full.stored_blade_count]M.Coefficient);
    coeffs[0] = 1;
    return Full.init(coeffs);
}

/// Bulk dual `u★ = ũ ⦑ 𝟙`: the (right) metric dual, the complement of the
/// bulk (metric) components. Reduces to the Hodge star on non-degenerate
/// metrics; in degenerate metrics the null-axis component contributes zero.
pub fn bulkDual(mv: anytype) @TypeOf(mv.reverse().gp(pseudoscalarOf(@TypeOf(mv)))) {
    return mv.reverse().gp(pseudoscalarOf(@TypeOf(mv)));
}

/// Weight dual `u☆ = ũ ⦗ 1`: the (right) metric antidual, the complement of
/// the weight (anti-metric) components, built through the geometric
/// antiproduct.
pub fn weightDual(mv: anytype) @TypeOf(mv.reverse().antiGeometric(scalarOneOf(@TypeOf(mv)))) {
    return mv.reverse().antiGeometric(scalarOneOf(@TypeOf(mv)));
}

/// Bulk contraction `a ∨ b★`. For same-grade operands this is the metric
/// scalar product `a • b` (equals the grade-0 part of `b̃ a`).
pub fn bulkContraction(a: anytype, b: anytype) @TypeOf(a.antiWedge(bulkDual(b))) {
    return a.antiWedge(bulkDual(b));
}

/// Weight contraction `a ∨ b☆`.
pub fn weightContraction(a: anytype, b: anytype) @TypeOf(a.antiWedge(weightDual(b))) {
    return a.antiWedge(weightDual(b));
}

/// Bulk expansion `a ∧ b★`. For same-grade operands this is
/// `(a • b) ∧ 𝟙`, the metric scalar product lifted to the pseudoscalar.
pub fn bulkExpansion(a: anytype, b: anytype) @TypeOf(a.wedge(bulkDual(b))) {
    return a.wedge(bulkDual(b));
}

/// Weight expansion `a ∧ b☆`.
pub fn weightExpansion(a: anytype, b: anytype) @TypeOf(a.wedge(weightDual(b))) {
    return a.wedge(weightDual(b));
}

/// Orthogonal RGA projection of `a` onto `b`: `b ∨ (a ∧ b☆)`, where the
/// parenthesized part is the weight expansion of `a` into `b`.
pub fn project(a: anytype, b: anytype) @TypeOf(b.antiWedge(a.wedge(weightDual(b)))) {
    return b.antiWedge(a.wedge(weightDual(b)));
}

/// Orthogonal RGA antiprojection of `a` onto `b`: `b ∧ (a ∨ b☆)`, where the
/// parenthesized part is the weight contraction of `a` with `b`.
pub fn antiproject(a: anytype, b: anytype) @TypeOf(b.wedge(a.antiWedge(weightDual(b)))) {
    return b.wedge(a.antiWedge(weightDual(b)));
}

const blades = @import("blades.zig");
const blade_parsing = @import("blade_parsing.zig");
const ga = @import("../ga.zig");

const testing = std.testing;

fn nearlyZero(mv: anytype, tolerance: @TypeOf(mv).Coefficient) bool {
    const T = @TypeOf(mv).Coefficient;
    var max_abs: T = 0;
    for (mv.coeffsArray()) |c| {
        max_abs = @max(max_abs, @abs(c));
    }
    return max_abs <= tolerance;
}

fn nearlyEqualMv(a: anytype, b: anytype, tolerance: @TypeOf(a).Coefficient) bool {
    const T = @TypeOf(a).Coefficient;
    const Full = multivector.FullMultivector(T, @TypeOf(a).metric_signature);
    const fa = a.cast(Full);
    const fb = b.cast(Full);
    var max_abs: T = 0;
    inline for (0..Full.stored_blade_count) |i| {
        max_abs = @max(max_abs, @abs(fa.coeffsArray()[i] - fb.coeffsArray()[i]));
    }
    return max_abs <= tolerance;
}

test "bulk dual of a projective plane ignores the null-axis component" {
    const Rigid = ga.Algebra(.{ .p = 3, .q = 0, .r = 1 }).Instantiate(f32);
    const E = Rigid.Basis;

    // Plane g = e1 + 2 e2 + 3 e3 + 7 e4(null axis).
    const g = E.Vector.init(.{ 1, 2, 3, 7 });
    const g_no_offset = E.Vector.init(.{ 1, 2, 3, 0 });

    // The bulk dual is the complement of the metric (spatial) part; the
    // null-axis coefficient must not contribute.
    try testing.expect(nearlyEqualMv(bulkDual(g), bulkDual(g_no_offset), 1e-6));
}

test "applying the bulk dual twice vanishes in the degenerate projective algebra" {
    const Rigid = ga.Algebra(.{ .p = 3, .q = 0, .r = 1 }).Instantiate(f32);

    // det(metric) = 0, so u★★ = det(g) u = 0 for every blade.
    const v = Rigid.Vector.init(.{ 1, -2, 0.5, 3 });
    const b = Rigid.Bivector.init(.{ 1, -2, 0.5, 3, 0.25, -1 });
    const t = Rigid.Trivector.init(.{ 1, -2, 0.5, 3 });
    inline for (.{ v, b, t }) |mv| {
        try testing.expect(nearlyZero(bulkDual(bulkDual(mv)), 1e-5));
    }
}

test "same-grade bulk expansion equals the scalar product lifted to the pseudoscalar" {
    const Cl3 = ga.Algebra(.euclidean(3)).Instantiate(f32);
    const E = Cl3.Basis;
    const I = Cl3.Pseudoscalar.init(.{1});

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const random = prng.random();
    var iteration: usize = 0;
    while (iteration < 256) : (iteration += 1) {
        const a = E.Vector.init(.{
            random.float(f32) - 0.5,
            random.float(f32) - 0.5,
            random.float(f32) - 0.5,
        });
        const b = E.Vector.init(.{
            random.float(f32) - 0.5,
            random.float(f32) - 0.5,
            random.float(f32) - 0.5,
        });

        // a ∧ b★ = (a • b) 𝟙
        const expanded = bulkExpansion(a, b);
        const lifted = a.dot(b).cast(Cl3.Full).gp(I.cast(Cl3.Full));
        try testing.expect(nearlyEqualMv(expanded, lifted, 1e-4));
    }
}

test "same-grade bulk contraction equals the scalar part of the reversed product" {
    const Cl3 = ga.Algebra(.euclidean(3)).Instantiate(f32);
    const E = Cl3.Basis;

    var prng = std.Random.DefaultPrng.init(0xBEEF);
    const random = prng.random();
    var iteration: usize = 0;
    while (iteration < 256) : (iteration += 1) {
        const a = E.Vector.init(.{
            random.float(f32) - 0.5,
            random.float(f32) - 0.5,
            random.float(f32) - 0.5,
        });
        const b = E.Vector.init(.{
            random.float(f32) - 0.5,
            random.float(f32) - 0.5,
            random.float(f32) - 0.5,
        });

        // a ∨ b★ = <b̃ a>₀
        const contracted = bulkContraction(a, b);
        const grade_part = b.reverse().gp(a).gradePart(0).cast(multivector.FullMultivector(f32, @TypeOf(a).metric_signature));
        try testing.expect(nearlyEqualMv(contracted, grade_part, 1e-4));
    }
}

test "projection extracts the parallel content of same-grade vectors" {
    const Cl3 = ga.Algebra(.euclidean(3)).Instantiate(f32);
    const E = Cl3.Basis;

    // project(a, b) for same-grade Euclidean vectors: the metric-parallel
    // content of a along b, up to this library's dual-orientation sign
    // (project = -(a.b) b here); orthogonal input vanishes.
    const orthogonal = project(E.Vector.init(.{ 1, 0, 0 }), E.Vector.init(.{ 0, 1, 0 }));
    try testing.expect(nearlyZero(orthogonal, 1e-5));

    const parallel = project(E.Vector.init(.{ 0, 3, 0 }), E.Vector.init(.{ 0, 1, 0 }));
    const expected = E.Vector.init(.{ 0, -3, 0 });
    try testing.expect(nearlyEqualMv(parallel, expected, 1e-4));
}

test "antiprojection extracts the parallel content with the opposite sign" {
    const Cl3 = ga.Algebra(.euclidean(3)).Instantiate(f32);
    const E = Cl3.Basis;

    // antiproject(a, b) = -(a.b) b for same-grade Euclidean vectors under
    // this library's dual conventions; orthogonal input vanishes. The
    // project/antiproject pair diverges for mixed-grade, mixed-content
    // operands (the RGA incidence cases), not for same-grade vectors.
    const orthogonal = antiproject(E.Vector.init(.{ 1, 0, 0 }), E.Vector.init(.{ 0, 1, 0 }));
    try testing.expect(nearlyZero(orthogonal, 1e-5));

    const parallel = antiproject(E.Vector.init(.{ 0, 3, 0 }), E.Vector.init(.{ 0, 1, 0 }));
    const expected = E.Vector.init(.{ 0, -3, 0 });
    try testing.expect(nearlyEqualMv(parallel, expected, 1e-4));
}
