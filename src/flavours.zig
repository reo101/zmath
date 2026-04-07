const std = @import("std");

pub const vga = @import("flavours/vga.zig");
pub const pga = @import("flavours/pga.zig");
pub const hpga = @import("flavours/hpga.zig");
pub const epga = @import("flavours/epga.zig");
pub const sta = @import("flavours/sta.zig");
pub const cga = @import("flavours/cga.zig");

test "flavour facades expose canonical binding metadata" {
    inline for (.{
        vga,
        pga,
        hpga,
        epga,
        sta,
        cga,
    }) |Flavour| {
        comptime {
            try std.testing.expect(@hasDecl(Flavour, "Family"));
            try std.testing.expect(@hasDecl(Flavour, "default_scalar"));
            try std.testing.expect(@hasDecl(Flavour, "metric_signature"));
            try std.testing.expect(@hasDecl(Flavour, "dimension"));
            try std.testing.expect(@hasDecl(Flavour, "Algebra"));
            try std.testing.expect(@hasDecl(Flavour, "Instantiate"));
            try std.testing.expect(@hasDecl(Flavour, "h"));
            try std.testing.expect(@hasDecl(Flavour, "FamilyHelpers"));
            try std.testing.expect(@hasDecl(Flavour, "InstantiateHelpers"));
        }

        try std.testing.expectEqual(Flavour.metric_signature.dimension(), Flavour.dimension);
    }
}
