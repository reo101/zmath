const std = @import("std");
const zmath = @import("zmath");
const canvas_api = zmath.render.canvas;
const demo = @import("core.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout_fd = std.posix.STDOUT_FILENO;
    const stdin_fd = std.posix.STDIN_FILENO;

    const original_termios = try std.posix.tcgetattr(stdin_fd);
    var raw = original_termios;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.cc[@intFromEnum(std.posix.system.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.system.V.TIME)] = 0;
    try std.posix.tcsetattr(stdin_fd, .FLUSH, raw);
    defer std.posix.tcsetattr(stdin_fd, .FLUSH, original_termios) catch {};

    var width: usize = 80;
    var height: usize = 40;
    var ws: std.posix.winsize = undefined;
    const TIOCGWINSZ: usize = 0x5413;
    if (std.posix.system.ioctl(stdout_fd, TIOCGWINSZ, @intFromPtr(&ws)) >= 0) {
        width = ws.col;
        height = ws.row;
    }

    var canvas = try canvas_api.Canvas.init(allocator, width, height);
    defer canvas.deinit();

    var app = try demo.App.init();

    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();
    var stdout_buffer: [32768]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("\x1B[?25l\x1B[2J");
    defer {
        stdout.writeAll("\x1B[?25h") catch {};
        stdout.flush() catch {};
    }

    while (true) {
        app.tick();

        var input_buf: [16]u8 = undefined;
        if (std.posix.read(stdin_fd, &input_buf)) |bytes_read| {
            if (bytes_read > 0 and app.processTerminalBytes(input_buf[0..bytes_read])) {
                break;
            }
        } else |_| {}

        const frame = app.render(&canvas, width, height);

        try stdout.writeAll("\x1B[H");
        try frame.writeStatusLine(stdout);
        try canvas.writeRowsToWriter(stdout, canvas.height - 1);
        try stdout.flush();

        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(30), .awake) catch {};
    }
}
