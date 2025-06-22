const std = @import("std");

pub fn main() !void {
    const stdin = std.io.getStdIn().reader();
    while (true) {
        const c = stdin.readByte() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (c == 'q') {
            return;
        }
    }
}
