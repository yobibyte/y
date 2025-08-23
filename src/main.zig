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

pub fn die(err: anyerror) void {
    std.debug.print("{}", .{err});
    std.posix.exit(1);
}

pub fn main() !void {
    const stdin = std.io.getStdIn();
    const reader = stdin.reader();
    const handle = stdin.handle;
    enable_raw_mode(handle) catch |err| die(err);
    defer disable_raw_mode(handle) catch |err| die(err);

    while (true) {
        var c: u8 = 0;
        if (reader.readByte()) |b| {
            c = b;
        } else |err| switch (err) {
            error.EndOfStream => {
                c = 0;
            },
            else => |other_err| die(other_err),
        }
        if (c == ctrl_key('q')) {
            break;
        }
        if (std.ascii.isControl(c)) {
            std.debug.print("{}\r\n", .{c});
        } else {
            std.debug.print("{} ('{c}')\r\n", .{ c, c });
        }
    }
}
