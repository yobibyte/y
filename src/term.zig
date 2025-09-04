const std = @import("std");
const posix = std.posix;

pub fn getWindowSize(writer: *const std.fs.File) ![2]usize {
    var ws: posix.winsize = undefined;
    const err = std.os.linux.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws));

    if (posix.errno(err) == .SUCCESS) {
        return .{ ws.row, ws.col };
    } else {
        // If ioctl failed, we will move cursor to the bottom right position and get its coordinates.
        try writer.writeAll("\x1b[999C\x1b[999B");
        return getCursorPosition(writer);
    }
}
fn getCursorPosition(writer: *const std.fs.File) ![2]usize {
    try writer.writeAll("\x1b[6n");
    const stdin = std.fs.File.stdin();
    var stdin_buffer: [1024]u8 = undefined;
    var reader = stdin.reader(&stdin_buffer);

    //[2..] because we get an escape sequence coming back.
    // It looks like 27[rows;colsR, we need to parse it.
    // var buf: [32]u8 = undefined;
    const line = try reader.interface.takeDelimiterExclusive('R');
    var tokenizer = std.mem.splitScalar(u8, line[2..], ';');

    // Have some default values in case this thing fails.
    const rows = try std.fmt.parseInt(usize, tokenizer.next() orelse "25", 10);
    const cols = try std.fmt.parseInt(usize, tokenizer.next() orelse "80", 10);

    return .{ rows, cols };
}
