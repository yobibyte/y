const std = @import("std");

var orig_term: std.posix.system.termios = undefined;

pub fn enable_raw_mode(handle: std.posix.fd_t) !void {
    orig_term = try std.posix.tcgetattr(handle);
    var term = orig_term;
    term.lflag.ECHO = !term.lflag.ECHO;
    term.lflag.ICANON = !term.lflag.ICANON;
    try std.posix.tcsetattr(handle, .NOW, term);
}
pub fn disable_raw_mode(handle: std.posix.fd_t) !void {
    try std.posix.tcsetattr(handle, .NOW, orig_term);
}

pub fn main() !void {
    const stdin = std.io.getStdIn();
    const reader = stdin.reader();
    const handle = stdin.handle;
    try enable_raw_mode(handle);
    defer disable_raw_mode(handle) catch |err| {
        std.debug.print("Error: {} when setting the terminal flags back to original", .{err});
    };
    while (true) {
        const c = reader.readByte() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (c == 'q') {
            return;
        }
        if (std.ascii.isControl(c)) {
            std.debug.print("{}\n", .{c});
        } else {
            std.debug.print("{} ('{c}')\n", .{ c, c });
        }
    }
}
