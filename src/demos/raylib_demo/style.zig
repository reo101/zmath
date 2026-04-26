const rl = @import("raylib");

pub const bg_top = rl.Color{ .r = 11, .g = 17, .b = 22, .a = 255 };
pub const bg_bottom = rl.Color{ .r = 3, .g = 6, .b = 10, .a = 255 };
pub const panel = rl.Color{ .r = 229, .g = 224, .b = 209, .a = 255 };
pub const panel_alt = rl.Color{ .r = 215, .g = 222, .b = 221, .a = 255 };
pub const ink = rl.Color{ .r = 19, .g = 23, .b = 25, .a = 255 };
pub const muted = rl.Color{ .r = 88, .g = 99, .b = 105, .a = 255 };
pub const faint = rl.Color{ .r = 141, .g = 150, .b = 154, .a = 255 };
pub const paper_line = rl.Color{ .r = 190, .g = 185, .b = 169, .a = 255 };
pub const shadow = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 82 };
pub const amber = rl.Color{ .r = 255, .g = 178, .b = 66, .a = 255 };
pub const coral = rl.Color{ .r = 245, .g = 96, .b = 83, .a = 255 };
pub const cyan = rl.Color{ .r = 89, .g = 205, .b = 240, .a = 255 };
pub const moss = rl.Color{ .r = 94, .g = 165, .b = 126, .a = 255 };
pub const violet = rl.Color{ .r = 132, .g = 118, .b = 222, .a = 255 };
pub const white = rl.Color{ .r = 246, .g = 247, .b = 241, .a = 255 };

pub fn alpha(color: rl.Color, a: u8) rl.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = a };
}
