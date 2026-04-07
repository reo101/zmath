const zmath = @import("zmath");
const ga = zmath.ga;
const blades = ga.blades;
const multivector = ga.multivector;

const Sig8 = ga.euclideanSignature(8);
const Cl8 = ga.Algebra(Sig8).Instantiate(f64);
const Full8 = Cl8.Full;
const Rotor8 = Cl8.Rotor;
const Vector8 = Cl8.Vector;

// Direct mask builders. These isolate the blade-set combinator cost.
const Full8BladeIndex = blades.bladeIndexByMask(Sig8.dimension(), Full8.blades);
const Full8GeometricMasks = blades.geometricProductMasks(Sig8.dimension(), Full8.blades, Full8.blades);
const Full8OuterMasks = blades.outerProductMasks(Sig8.dimension(), Full8.blades, Full8.blades);
const Full8LeftContractionMasks = blades.leftContractionMasks(Sig8.dimension(), Full8.blades, Full8.blades);
const Full8RightContractionMasks = blades.rightContractionMasks(Sig8.dimension(), Full8.blades, Full8.blades);
const Full8DualMasks = blades.dualMasks(Sig8.dimension(), Full8.blades);

// Result carriers. These are the declarations users tend to name directly.
const Full8Add = multivector.AddResultType(f64, Full8.blades, Full8.blades, Sig8);
const Full8Geometric = multivector.GeometricProductResultType(f64, Full8.blades, Full8.blades, Sig8);
const Full8Outer = multivector.OuterProductResultType(f64, Full8.blades, Full8.blades, Sig8);
const Full8LeftContraction = multivector.LeftContractionResultType(f64, Full8.blades, Full8.blades, Sig8);
const Full8RightContraction = multivector.RightContractionResultType(f64, Full8.blades, Full8.blades, Sig8);
const Full8Dot = multivector.DotProductResultType(f64, Full8.blades, Full8.blades, Sig8);
const Full8Join = multivector.JoinResultType(f64, Full8.blades, Full8.blades, Sig8);

// Representative smaller shapes help distinguish "full/full is expensive"
// from "all product builders are expensive".
const Rotor8Geometric = multivector.GeometricProductResultType(f64, Rotor8.blades, Rotor8.blades, Sig8);
const Vector8Geometric = multivector.GeometricProductResultType(
    f64,
    Vector8.blades,
    Vector8.blades,
    Sig8,
);

comptime {
    _ = Full8;
    _ = Rotor8;
    _ = Vector8;

    _ = Full8BladeIndex;
    _ = Full8GeometricMasks;
    _ = Full8OuterMasks;
    _ = Full8LeftContractionMasks;
    _ = Full8RightContractionMasks;
    _ = Full8DualMasks;

    _ = Full8Add;
    _ = Full8Geometric;
    _ = Full8Outer;
    _ = Full8LeftContraction;
    _ = Full8RightContraction;
    _ = Full8Dot;
    _ = Full8Join;

    _ = Rotor8Geometric;
    _ = Vector8Geometric;
}

pub fn main() void {}
