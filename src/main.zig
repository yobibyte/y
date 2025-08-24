const std = @import("std");

var orig_term: std.posix.system.termios = undefined;

inline fn ctrl_key(k: u8) u8 {
    return k & 0x1f;
}

pub fn enable_raw_mode(handle: std.posix.fd_t) !void {
    orig_term = try std.posix.tcgetattr(handle);
    var term = orig_term;
    term.lflag.ECHO = !term.lflag.ECHO;
    term.lflag.ISIG = !term.lflag.ISIG;
    term.lflag.ICANON = !term.lflag.ICANON;
    term.lflag.IEXTEN = !term.lflag.IEXTEN;
    term.iflag.IXON = !term.iflag.IXON;
    term.iflag.ICRNL = !term.iflag.ICRNL;
    term.iflag.BRKINT = !term.iflag.BRKINT;
    term.iflag.INPCK = !term.iflag.INPCK;
    term.iflag.ISTRIP = !term.iflag.ISTRIP;
    term.oflag.OPOST = !term.oflag.OPOST;
    term.cflag.CSIZE = std.posix.CSIZE.CS8;
    term.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    term.cc[@intFromEnum(std.posix.V.TIME)] = 1;
    try std.posix.tcsetattr(handle, .NOW, term);
}

pub fn disable_raw_mode(handle: std.posix.fd_t) !void {
    try std.posix.tcsetattr(handle, .NOW, orig_term);
}

fn editor_read_key(reader: *const std.io.AnyReader) !u8 {
    return reader.readByte() catch |err| switch (err) {
        error.EndOfStream => return 0,
        else => err,
    };
}

fn editor_process_keypress(reader: *const std.io.AnyReader) !bool {
    const c = try editor_read_key(reader);
    switch (c) {
        ctrl_key('q') => return false,
        else => {
            if (std.ascii.isControl(c)) {
                std.debug.print("{}\r\n", .{c});
            } else {
                std.debug.print("{} ('{c}')\r\n", .{ c, c });
            }
            return true;
        },
    }
}

fn editor_refresh_screen() !void {
    const writer = std.io.getStdOut();
    try writer.writeAll("\x1b[2J");
    try writer.writeAll("\x1b[H");
}

pub fn main() !void {
    const stdin = std.io.getStdIn();
    const reader = stdin.reader().any();
    const handle = stdin.handle;
    try enable_raw_mode(handle);
    defer disable_raw_mode(handle) catch |err| {
        std.debug.print("Failed to disable raw mode: {}", .{err});
    };
    // I am not sure whether this will clear the error message or not.
    errdefer editor_refresh_screen() catch |err| {
        std.debug.print("Failed to clear screen: {}", .{err});
    };

    while (true) {
        try editor_refresh_screen();
        if (!try editor_process_keypress(&reader)) {
            break;
        }
    }
}
