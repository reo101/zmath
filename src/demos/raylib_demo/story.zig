const zmath = @import("zmath");

const Vga2 = zmath.flavours.vga.FamilyHelpers(zmath.flavours.vga.EuclideanFamily(2), f32);
const Pga2 = zmath.flavours.pga.FamilyHelpers(zmath.flavours.pga.EuclideanFamily(2), f32);
const Cga2 = zmath.flavours.cga.FamilyHelpers(zmath.flavours.cga.EuclideanFamily(2), f32);

pub const Sample = struct {
    x: f32,
    y: f32,
    r2: f32,
    vga_norm2: f32,
    pga_point: [3]f32,
    pga_direction: [3]f32,
    cga_lift: f32,
    cga_null_error: f32,
};

pub fn sampleAt(t: f32) Sample {
    const x = 1.35 * @cos(t * 0.72);
    const y = 0.80 * @sin(t * 1.11);
    const r2 = x * x + y * y;

    const vga_vector = Vga2.h.Vector.init(.{ x, y });
    const pga_point = Pga2.Point.fromCoords(.{ x, y });
    const pga_direction = Pga2.Point.directionFromCoords(.{ 1.0, 0.0 });
    const cga_point = Cga2.Point.fromCoords(.{ x, y });

    return .{
        .x = x,
        .y = y,
        .r2 = r2,
        .vga_norm2 = Vga2.normSquared(vga_vector),
        .pga_point = Pga2.ambientCoords(pga_point),
        .pga_direction = Pga2.ambientCoords(pga_direction),
        .cga_lift = 0.5 * r2,
        .cga_null_error = Cga2.h.normSquared(cga_point),
    };
}
