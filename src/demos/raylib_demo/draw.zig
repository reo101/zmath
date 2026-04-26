const std = @import("std");
const rl = @import("raylib");
const style = @import("style.zig");

pub fn text(msg: [:0]const u8, x: f32, y: f32, size: i32, color: rl.Color) void {
    rl.drawText(msg, toInt(x), toInt(y), size, color);
}

pub fn textFmt(
    buffer: []u8,
    x: f32,
    y: f32,
    size: i32,
    color: rl.Color,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const msg = std.fmt.bufPrintZ(buffer, fmt, args) catch return;
    text(msg, x, y, size, color);
}

pub fn panel(rect: rl.Rectangle, fill: rl.Color, title: [:0]const u8, accent: rl.Color) void {
    rl.drawRectangleRec(offsetRect(rect, 8.0, 10.0), style.shadow);
    rl.drawRectangleRec(rect, fill);
    rl.drawRectangleRec(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = 7.0 }, accent);
    rl.drawRectangleLinesEx(rect, 1.5, style.alpha(style.ink, 70));
    text(title, rect.x + 22.0, rect.y + 22.0, 28, style.ink);
}

pub fn line(a: rl.Vector2, b: rl.Vector2, width: f32, color: rl.Color) void {
    rl.drawLineEx(a, b, width, color);
}

pub fn arrow(a: rl.Vector2, b: rl.Vector2, width: f32, color: rl.Color) void {
    line(a, b, width, color);

    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.001) return;

    const ux = dx / len;
    const uy = dy / len;
    const side = rl.Vector2{ .x = -uy, .y = ux };
    const back = rl.Vector2{ .x = b.x - ux * 13.0, .y = b.y - uy * 13.0 };
    const left = rl.Vector2{ .x = back.x + side.x * 6.0, .y = back.y + side.y * 6.0 };
    const right = rl.Vector2{ .x = back.x - side.x * 6.0, .y = back.y - side.y * 6.0 };

    rl.drawTriangle(b, left, right, color);
}

pub fn dot(center: rl.Vector2, radius: f32, color: rl.Color) void {
    rl.drawCircleV(center, radius + 4.0, style.alpha(color, 44));
    rl.drawCircleV(center, radius, color);
}

pub fn grid(rect: rl.Rectangle, units: f32, color: rl.Color) void {
    const center = centerOf(rect);
    var i: i32 = -4;
    while (i <= 4) : (i += 1) {
        const x = center.x + @as(f32, @floatFromInt(i)) * units;
        const y = center.y + @as(f32, @floatFromInt(i)) * units;
        line(.{ .x = x, .y = rect.y + 70.0 }, .{ .x = x, .y = rect.y + rect.height - 30.0 }, 1.0, color);
        line(.{ .x = rect.x + 24.0, .y = y }, .{ .x = rect.x + rect.width - 24.0, .y = y }, 1.0, color);
    }

    line(.{ .x = center.x, .y = rect.y + 70.0 }, .{ .x = center.x, .y = rect.y + rect.height - 30.0 }, 1.5, style.alpha(style.ink, 95));
    line(.{ .x = rect.x + 24.0, .y = center.y }, .{ .x = rect.x + rect.width - 24.0, .y = center.y }, 1.5, style.alpha(style.ink, 95));
}

pub fn plot(rect: rl.Rectangle, x: f32, y: f32, units: f32) rl.Vector2 {
    const center = centerOf(rect);
    return .{ .x = center.x + x * units, .y = center.y - y * units };
}

pub fn mapRect(rect: rl.Rectangle, x: f32, y: f32, bounds: Bounds) rl.Vector2 {
    const nx = (x - bounds.min_x) / (bounds.max_x - bounds.min_x);
    const ny = (y - bounds.min_y) / (bounds.max_y - bounds.min_y);
    return .{
        .x = rect.x + nx * rect.width,
        .y = rect.y + (1.0 - ny) * rect.height,
    };
}

pub const Bounds = struct {
    min_x: f32,
    max_x: f32,
    min_y: f32,
    max_y: f32,
};

pub fn inset(rect: rl.Rectangle, amount: f32) rl.Rectangle {
    return .{
        .x = rect.x + amount,
        .y = rect.y + amount,
        .width = rect.width - amount * 2.0,
        .height = rect.height - amount * 2.0,
    };
}

pub fn offsetRect(rect: rl.Rectangle, dx: f32, dy: f32) rl.Rectangle {
    return .{ .x = rect.x + dx, .y = rect.y + dy, .width = rect.width, .height = rect.height };
}

pub fn centerOf(rect: rl.Rectangle) rl.Vector2 {
    return .{ .x = rect.x + rect.width * 0.5, .y = rect.y + rect.height * 0.5 };
}

pub fn toInt(value: f32) i32 {
    return @intFromFloat(@round(value));
}
