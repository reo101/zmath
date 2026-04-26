const App = @import("raylib_demo/app.zig").App;

pub fn main() !void {
    var app = App.init();
    try app.run();
}
