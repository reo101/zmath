const std = @import("std");
const zmath = @import("zmath");
const demo = @import("demo_core");

const canvas_api = zmath.render.canvas;

fn dumpSnapshot(
    stdout: anytype,
    label: []const u8,
    app: *demo.App,
    canvas: *canvas_api.Canvas,
) !void {
    try stdout.print("\n== {s} ==\n", .{label});
    const frame = app.render(canvas, canvas.width, canvas.height);
    try frame.writeStatusLine(stdout);
    try canvas.writeRowsToWriter(stdout, canvas.height - 1);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.page_allocator;

    var stdout_buffer: [32768]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var canvas = try canvas_api.Canvas.init(allocator, 80, 40);
    defer canvas.deinit();

    var hyper = try demo.App.init();
    hyper.animate = false;
    hyper.mode = .hyperbolic;
    try dumpSnapshot(stdout, "hyperbolic default", &hyper, &canvas);
    _ = hyper.applyCommand(.more_curved);
    try dumpSnapshot(stdout, "hyperbolic more_curved", &hyper, &canvas);

    var spherical = try demo.App.init();
    spherical.animate = false;
    spherical.mode = .spherical;
    try dumpSnapshot(stdout, "spherical default", &spherical, &canvas);
    _ = spherical.applyCommand(.more_curved);
    try dumpSnapshot(stdout, "spherical more_curved", &spherical, &canvas);

    try stdout.flush();
}
