const std = @import("std");
const sg = @import("zmath").geometry.spherical_game;

pub const Vec4 = [4]f32;
pub const RotorCoefficients = [8]f32;

pub const Space = enum {
    spherical,
    euclidean,
    hyperbolic,
};

pub const Material = struct {
    name: []const u8,
    color: [4]f32,
    tone: f32 = 1.0,
};

pub const Face = struct {
    normal: Vec4,
    positive: bool = true,
    material: usize = 0,
};

pub const Bound = struct {
    center: Vec4,
    cos_radius: f32,
};

pub const Object = struct {
    name: []const u8,
    kind: enum { halfspaces },
    faces: []Face,
    bound: ?Bound = null,
    /// Optional Spin(4) rotor coefficients. JSON owns the interchange
    /// representation; all actual S3 transforms go through zmath GA.
    transform: ?RotorCoefficients = null,

    pub fn transformNormal(self: Object, normal: Vec4) Vec4 {
        const coefficients = self.transform orelse return normal;
        const rotor = sg.Rotor.init(coefficients);
        return sg.rotate(sg.Direction.init(normal), rotor).coeffsArray();
    }

    pub fn transformPoint(self: Object, point: Vec4) Vec4 {
        const coefficients = self.transform orelse return point;
        const rotor = sg.Rotor.init(coefficients);
        return sg.rotate(sg.Point.init(point), rotor).coeffsArray();
    }
};

pub const File = struct {
    version: u32,
    space: Space,
    radius: f32,
    materials: []Material,
    objects: []Object,

    pub fn validate(self: File) !void {
        if (self.version != 1) return error.UnsupportedVersion;
        if (!(self.radius > 0.0)) return error.InvalidRadius;
        if (self.materials.len == 0) return error.NoMaterials;
        for (self.objects) |object| {
            if (object.faces.len == 0 or object.faces.len > 6) return error.InvalidFaceCount;
            if (object.bound) |bound| {
                var center_norm_sq: f32 = 0.0;
                for (bound.center) |coefficient| center_norm_sq += coefficient * coefficient;
                if (@abs(center_norm_sq - 1.0) > 1e-3) return error.NonUnitBoundCenter;
                if (bound.cos_radius < -1.0 or bound.cos_radius > 1.0) return error.InvalidBoundRadius;
            }
            if (object.transform) |rotor| {
                var norm_sq: f32 = 0.0;
                for (rotor) |coefficient| norm_sq += coefficient * coefficient;
                if (@abs(norm_sq - 1.0) > 1e-3) return error.NonUnitRotor;
            }
            for (object.faces) |face| {
                const length = @sqrt(
                    face.normal[0] * face.normal[0] +
                        face.normal[1] * face.normal[1] +
                        face.normal[2] * face.normal[2] +
                        face.normal[3] * face.normal[3],
                );
                if (@abs(length - 1.0) > 1e-3) return error.NonUnitFaceNormal;
                if (face.material >= self.materials.len) return error.InvalidMaterial;
            }
        }
    }

    pub fn validateGpuCapacity(self: File, max_objects: usize, max_materials: usize) !void {
        if (self.objects.len > max_objects) return error.TooManyObjects;
        if (self.materials.len > max_materials) return error.TooManyMaterials;
        for (self.objects) |object| {
            for (object.faces) |face| {
                if (face.material >= max_materials) return error.MaterialCapacityExceeded;
            }
        }
    }
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !std.json.Parsed(File) {
    const parsed = try std.json.parseFromSlice(File, allocator, source, .{});
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

test "S3 object transforms use GA rotors" {
    const rotor = sg.rotorBetween(
        sg.Point.init(.{ 1, 0, 0, 0 }),
        sg.Point.init(.{ 0, 0, 0, 1 }),
        std.math.pi / 2.0,
    );
    const object = Object{
        .name = "rotated",
        .kind = .halfspaces,
        .faces = &.{},
        .bound = .{ .center = .{ 1, 0, 0, 0 }, .cos_radius = 0.9 },
        .transform = rotor.coeffsArray(),
    };
    const normal = object.transformNormal(.{ 1, 0, 0, 0 });
    const bound_center = object.transformPoint(object.bound.?.center);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), normal[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), normal[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), normal[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), @abs(normal[3]), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), bound_center[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), bound_center[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), bound_center[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), @abs(bound_center[3]), 1e-5);
}

test "rejects scenes beyond GPU capacities" {
    var materials = [_]Material{
        .{ .name = "one", .color = .{ 1, 1, 1, 1 } },
        .{ .name = "two", .color = .{ 1, 1, 1, 1 } },
    };
    var faces = [_]Face{.{ .normal = .{ 1, 0, 0, 0 }, .material = 1 }};
    var objects = [_]Object{.{
        .name = "object",
        .kind = .halfspaces,
        .faces = &faces,
    }};
    const file = File{
        .version = 1,
        .space = .spherical,
        .radius = 6.0,
        .materials = &materials,
        .objects = &objects,
    };

    try std.testing.expectError(error.TooManyObjects, file.validateGpuCapacity(0, 16));
    try std.testing.expectError(error.TooManyMaterials, file.validateGpuCapacity(64, 1));

    const limited_file = File{
        .version = 1,
        .space = .spherical,
        .radius = 6.0,
        .materials = materials[0..1],
        .objects = &objects,
    };
    try std.testing.expectError(error.MaterialCapacityExceeded, limited_file.validateGpuCapacity(64, 1));
}

test "parses a data-defined triangular prism" {
    const source = "{\"version\":1,\"space\":\"spherical\",\"radius\":6.0,\"materials\":[{\"name\":\"stone\",\"color\":[0.4,0.4,0.45,1.0],\"tone\":0.8}],\"objects\":[{\"name\":\"prism\",\"kind\":\"halfspaces\",\"faces\":[{\"normal\":[1,0,0,0]},{\"normal\":[-0.5,0.8660254,0,0]},{\"normal\":[-0.5,-0.8660254,0,0]},{\"normal\":[0,0,1,0]},{\"normal\":[0,0,-1,0]}]}]}";
    const parsed = try parse(std.testing.allocator, source);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.objects.len);
    try std.testing.expectEqual(@as(usize, 5), parsed.value.objects[0].faces.len);
}
