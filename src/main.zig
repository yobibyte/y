const std = @import("std");

var orig_term: std.posix.system.termios = undefined;

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

pub fn die(s: []const u8) void {
    // Replace this by spitting out the error itself.
    std.debug.print("{}", .{s});
    std.os.exit(1);
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
        var c: u8 = 0;
        if (reader.readByte()) |b| {
            c = b;
        } else |err| switch (err) {
            error.EndOfStream => {
                c = 0;
            },
            else => |other_err| return other_err,
        }
        if (c == 'q') {
            return;
        }
        if (std.ascii.isControl(c)) {
            std.debug.print("{}\r\n", .{c});
        } else {
            std.debug.print("{} ('{c}')\r\n", .{ c, c });
        }
    }
}
