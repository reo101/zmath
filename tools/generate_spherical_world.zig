const std = @import("std");
const scene = @import("spherical_scene");

const Point = scene.Point;
const Direction = scene.Direction;

fn dot(a: Point, b: Point) f32 {
    return scene.dot(a, b);
}

fn printVec(v: Point) void {
    std.debug.print("[{d:.9}, {d:.9}, {d:.9}, {d:.9}]", .{
        v.coeffNamed("e1"),
        v.coeffNamed("e2"),
        v.coeffNamed("e3"),
        v.coeffNamed("e4"),
    });
}

fn printBound(center: Point, cos_radius: f32) void {
    std.debug.print("      \"bound\": {{ \"center\": ", .{});
    printVec(center);
    std.debug.print(", \"cos_radius\": {d:.9} }},\n", .{cos_radius});
}

fn printFace(normal: Point, positive: bool, material: usize, comma: bool) void {
    std.debug.print("        {{ \"normal\": ", .{});
    printVec(normal);
    std.debug.print(", \"positive\": {}, \"material\": {d} }}{s}\n", .{ positive, material, if (comma) "," else "" });
}

fn printPlank(fence: scene.Fence, arc: f32, object_index: usize) void {
    const theta = arc / fence.radius;
    const sin_theta = @sin(theta);
    const cos_theta = @cos(theta);
    const radial = fence.anchor.cast(Direction).scale(cos_theta).add(fence.axis.scale(sin_theta));
    const pole = fence.pole.cast(Direction);
    const sin_half_width = @sin(0.5 * fence.width / fence.radius);
    const cos_half_width = @cos(0.5 * fence.width / fence.radius);
    const sin_half_thick = @sin(0.5 * fence.thickness / fence.radius);
    const cos_half_thick = @cos(0.5 * fence.thickness / fence.radius);
    const near = pole.scale(cos_half_thick).sub(radial.scale(sin_half_thick));
    const far = pole.scale(cos_half_thick).add(radial.scale(sin_half_thick));
    const low_raw = fence.anchor.cast(Direction)
        .scale(cos_theta * sin_half_width - sin_theta * cos_half_width)
        .add(fence.axis.scale(cos_theta * cos_half_width + sin_theta * sin_half_width));
    const high_raw = fence.anchor.cast(Direction)
        .scale(-(cos_theta * sin_half_width + sin_theta * cos_half_width))
        .add(fence.axis.scale(cos_theta * cos_half_width - sin_theta * sin_half_width));
    const low = if (dot(radial, low_raw) < 0.0) low_raw.negate() else low_raw;
    const high = if (dot(radial, high_raw) < 0.0) high_raw.negate() else high_raw;
    const sin_top = @sin(fence.height / fence.radius);
    const cos_top = @sqrt(1.0 - sin_top * sin_top);
    const world_up = Point.init(.{ 0, 0, 1, 0 });
    const cap = world_up.scale(cos_top).sub(radial.scale(sin_top));
    const center = radial.scale(@cos(0.5 * fence.height / fence.radius)).add(world_up.scale(@sin(0.5 * fence.height / fence.radius))).cast(Point);
    const bound_angle = (0.5 * fence.width + 0.5 * fence.thickness + fence.height) / fence.radius;

    std.debug.print("    {{\n      \"name\": \"picket_{d}\",\n      \"kind\": \"halfspaces\",\n", .{object_index});
    printBound(center, @cos(bound_angle));
    std.debug.print("      \"faces\": [\n", .{});
    printFace(near, false, 7, true);
    printFace(far, true, 7, true);
    printFace(low, true, 8, true);
    printFace(high, true, 8, true);
    printFace(cap, false, 9, true);
    printFace(world_up, true, 9, false);
    std.debug.print("      ]\n    }},\n", .{});
}

fn printRail(fence: scene.Fence, arc: f32, segment_width: f32, sin_lo: f32, cos_lo: f32, sin_hi: f32, cos_hi: f32, object_index: usize, last: bool) void {
    const theta = arc / fence.radius;
    const sin_theta = @sin(theta);
    const cos_theta = @cos(theta);
    const radial = fence.anchor.cast(Direction).scale(cos_theta).add(fence.axis.scale(sin_theta));
    const pole = fence.pole.cast(Direction);
    const sin_thick = @sin(0.5 * scene.default_fence_rail_thickness / fence.radius);
    const cos_thick = @cos(0.5 * scene.default_fence_rail_thickness / fence.radius);
    const near = pole.scale(cos_thick).sub(radial.scale(sin_thick));
    const far = pole.scale(cos_thick).add(radial.scale(sin_thick));
    const sin_half_width = @sin(0.5 * segment_width / fence.radius);
    const cos_half_width = @cos(0.5 * segment_width / fence.radius);
    const low_raw = fence.anchor.cast(Direction)
        .scale(cos_theta * sin_half_width - sin_theta * cos_half_width)
        .add(fence.axis.scale(cos_theta * cos_half_width + sin_theta * sin_half_width));
    const high_raw = fence.anchor.cast(Direction)
        .scale(-(cos_theta * sin_half_width + sin_theta * cos_half_width))
        .add(fence.axis.scale(cos_theta * cos_half_width - sin_theta * sin_half_width));
    const low = if (dot(radial, low_raw) < 0.0) low_raw.negate() else low_raw;
    const high = if (dot(radial, high_raw) < 0.0) high_raw.negate() else high_raw;
    const world_up = Point.init(.{ 0, 0, 1, 0 });
    const top = world_up.scale(cos_hi).sub(radial.scale(sin_hi));
    const bottom = world_up.scale(cos_lo).sub(radial.scale(sin_lo));
    const center_sin = 0.5 * (sin_lo + sin_hi);
    const center_cos = @sqrt(1.0 - center_sin * center_sin);
    const center = radial.scale(center_cos).add(world_up.scale(center_sin)).cast(Point);
    const bound_angle = (0.5 * segment_width + 0.5 * scene.default_fence_rail_thickness + 0.1) / fence.radius;

    std.debug.print("    {{\n      \"name\": \"rail_{d}\",\n      \"kind\": \"halfspaces\",\n", .{object_index});
    printBound(center, @cos(bound_angle));
    std.debug.print("      \"faces\": [\n", .{});
    printFace(near, false, 10, true);
    printFace(far, true, 10, true);
    printFace(low, true, 11, true);
    printFace(high, true, 11, true);
    printFace(top, false, 11, true);
    printFace(bottom, true, 11, false);
    std.debug.print("      ]\n    }}{s}\n", .{if (last) "" else ","});
}

pub fn main() void {
    const world = scene.Scene.init();
    const fence = world.fence;
    const half_circumference = std.math.pi * fence.radius;
    var arcs: [64]f32 = undefined;
    var count: usize = 0;
    var k: i32 = -64;
    while (k <= 64) : (k += 1) {
        const arc = @as(f32, @floatFromInt(k)) * fence.spacing - fence.spacing * 0.5 + fence.width * 0.5;
        if (arc >= -half_circumference and arc <= half_circumference) {
            arcs[count] = arc;
            count += 1;
        }
    }

    std.debug.print("{{\n  \"version\": 1,\n  \"space\": \"spherical\",\n  \"radius\": 6.0,\n  \"materials\": [\n", .{});
    std.debug.print("    {{\"name\":\"stone\",\"color\":[0.4,0.4,0.45,1.0],\"tone\":0.8}},\n", .{});
    std.debug.print("    {{\"name\":\"left_cyan\",\"color\":[0.3215686,0.745098,0.878431,1.0],\"tone\":0.8}},\n", .{});
    std.debug.print("    {{\"name\":\"right_coral\",\"color\":[0.9607843,0.3764706,0.3254902,1.0],\"tone\":0.8}},\n", .{});
    std.debug.print("    {{\"name\":\"bottom\",\"color\":[0.1176471,0.1333333,0.172549,1.0],\"tone\":0.8}},\n", .{});
    std.debug.print("    {{\"name\":\"top_amber\",\"color\":[1.0,0.7215686,0.3019608,1.0],\"tone\":0.8}},\n", .{});
    std.debug.print("    {{\"name\":\"front_green\",\"color\":[0.3607843,0.6784314,0.4941176,1.0],\"tone\":0.8}},\n", .{});
    std.debug.print("    {{\"name\":\"back_violet\",\"color\":[0.5607843,0.4862745,0.9019608,1.0],\"tone\":0.8}},\n", .{});
    std.debug.print("    {{\"name\":\"fence_face\",\"color\":[0.8862745,0.854902,0.7607843,1.0],\"tone\":0.78}},\n", .{});
    std.debug.print("    {{\"name\":\"fence_edge\",\"color\":[0.8862745,0.854902,0.7607843,1.0],\"tone\":0.34}},\n", .{});
    std.debug.print("    {{\"name\":\"fence_cap\",\"color\":[0.8862745,0.854902,0.7607843,1.0],\"tone\":0.88}},\n", .{});
    std.debug.print("    {{\"name\":\"rail_face\",\"color\":[0.8862745,0.854902,0.7607843,1.0],\"tone\":0.66}},\n", .{});
    std.debug.print("    {{\"name\":\"rail_edge\",\"color\":[0.8862745,0.854902,0.7607843,1.0],\"tone\":0.30}}\n", .{});
    std.debug.print("  ],\n  \"objects\": [\n", .{});
    std.debug.print("    {{\n      \"name\": \"cube\",\n      \"kind\": \"halfspaces\",\n", .{});
    printBound(world.cube.center, @cos(@sqrt(3.0) * world.cube.half_extent / world.radius));
    std.debug.print("      \"faces\": [\n", .{});
    for (world.cube.planes, 0..) |plane, i| {
        std.debug.print("        {{ \"normal\": ", .{});
        printVec(plane.inward_normal);
        std.debug.print(", \"positive\": true, \"material\": {d} }}{s}\n", .{ i + 1, if (i == 5) "" else "," });
    }
    std.debug.print("      ]\n    }},\n", .{});
    for (arcs[0..count], 0..) |arc, i| printPlank(fence, arc, i + 1);
    const segment_width = 2.0 * std.math.pi * fence.radius / 6.0;
    var rail_index = count + 1;
    for (0..6) |segment| {
        const arc = -std.math.pi * fence.radius + segment_width * (@as(f32, @floatFromInt(segment)) + 0.5);
        printRail(fence, arc, segment_width, @sin(0.50 / fence.radius), @cos(0.50 / fence.radius), @sin(0.60 / fence.radius), @cos(0.60 / fence.radius), rail_index, false);
        rail_index += 1;
    }
    for (0..6) |segment| {
        const arc = -std.math.pi * fence.radius + segment_width * (@as(f32, @floatFromInt(segment)) + 0.5);
        printRail(fence, arc, segment_width, @sin(1.25 / fence.radius), @cos(1.25 / fence.radius), @sin(1.35 / fence.radius), @cos(1.35 / fence.radius), rail_index, segment == 5);
        rail_index += 1;
    }
    std.debug.print("  ]\n}}\n", .{});
}
