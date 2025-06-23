const std = @import("std");

pub fn main() !void {
    const stdin = std.io.getStdIn();
    const reader = stdin.reader();
    var term = try std.posix.tcgetattr(stdin.handle);
    term.lflag.ECHO = !term.lflag.ECHO;
    try std.posix.tcsetattr(stdin.handle, .NOW, term);
    while (true) {
        const c = reader.readByte() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (c == 'q') {
            return;
        }
    }
    term.lflag.ECHO = !term.lflag.ECHO;
    try std.posix.tcsetattr(stdin.handle, .NOW, term);
}
