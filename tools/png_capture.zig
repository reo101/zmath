//! Opaque framebuffer PNG capture, using stored DEFLATE blocks.
const std = @import("std");

pub fn encode(allocator: std.mem.Allocator, width: u32, height: u32, pixels: []const u8, bgra: bool, srgb: bool) ![]u8 {
    if (width == 0 or height == 0 or pixels.len != @as(usize, width) * height * 4) return error.InvalidFrameSize;
    var rows: std.ArrayList(u8) = .empty;
    defer rows.deinit(allocator);
    for (0..height) |y| {
        try rows.append(allocator, 0); // No PNG row filter.
        for (0..width) |x| {
            const offset = (y * width + x) * 4;
            try rows.appendSlice(allocator, &.{
                pixels[offset + (if (bgra) @as(usize, 2) else 0)],
                pixels[offset + 1],
                pixels[offset + (if (bgra) @as(usize, 0) else 2)],
                255, // The swapchain window uses opaque compositing.
            });
        }
    }
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(allocator);
    try compressed.appendSlice(allocator, &.{ 0x78, 0x01 });
    var offset: usize = 0;
    while (offset < rows.items.len) {
        const length: u16 = @intCast(@min(65535, rows.items.len - offset));
        try compressed.append(allocator, if (offset + length == rows.items.len) 1 else 0);
        var lengths: [4]u8 = undefined;
        std.mem.writeInt(u16, lengths[0..2], length, .little);
        std.mem.writeInt(u16, lengths[2..4], ~length, .little);
        try compressed.appendSlice(allocator, &lengths);
        try compressed.appendSlice(allocator, rows.items[offset..][0..length]);
        offset += length;
    }
    try appendInt(&compressed, allocator, std.hash.Adler32.hash(rows.items));
    var png: std.ArrayList(u8) = .empty;
    errdefer png.deinit(allocator);
    try png.appendSlice(allocator, &.{ 137, 80, 78, 71, 13, 10, 26, 10 });
    var header: [13]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    header[8] = 8;
    header[9] = 6;
    try appendChunk(&png, allocator, "IHDR", &header);
    if (srgb) {
        try appendChunk(&png, allocator, "sRGB", &.{0});
    } else {
        // UNORM framebuffer bytes encode linear light, with file gamma 1.
        try appendChunk(&png, allocator, "gAMA", &.{ 0, 1, 134, 160 });
    }
    try appendChunk(&png, allocator, "IDAT", compressed.items);
    try appendChunk(&png, allocator, "IEND", &.{});
    return png.toOwnedSlice(allocator);
}

fn appendInt(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, value, .big);
    try bytes.appendSlice(allocator, &encoded);
}

fn appendChunk(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, name: *const [4]u8, data: []const u8) !void {
    try appendInt(bytes, allocator, @intCast(data.len));
    const start = bytes.items.len;
    try bytes.appendSlice(allocator, name);
    try bytes.appendSlice(allocator, data);
    try appendInt(bytes, allocator, std.hash.Crc32.hash(bytes.items[start..]));
}

test "PNG capture encodes BGRA as an opaque RGBA row" {
    try std.testing.expectError(error.InvalidFrameSize, encode(std.testing.allocator, 0, 1, &.{}, false, false));
    try std.testing.expectError(error.InvalidFrameSize, encode(std.testing.allocator, 1, 1, &.{ 10, 20, 30 }, false, false));
    inline for (.{ false, true }) |srgb| {
        const png = try encode(std.testing.allocator, 1, 1, &.{ 10, 20, 30, 40 }, true, srgb);
        defer std.testing.allocator.free(png);
        const metadata_length: usize = if (srgb) 13 else 16;
        try std.testing.expectEqual(@as(usize, 73) + metadata_length, png.len);
        try std.testing.expectEqualSlices(u8, &.{ 137, 80, 78, 71, 13, 10, 26, 10 }, png[0..8]);
        try std.testing.expectEqualSlices(u8, if (srgb) "sRGB" else "gAMA", png[37..41]);
        try std.testing.expectEqualSlices(u8, if (srgb) &.{0} else &.{ 0, 1, 134, 160 }, png[41 .. 41 + metadata_length - 12]);
        try std.testing.expectEqualSlices(u8, &.{ 0, 30, 20, 10, 255 }, png[48 + metadata_length .. 53 + metadata_length]);
    }
}
