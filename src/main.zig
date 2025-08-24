const std = @import("std");
const posix = std.posix;

const EditorState = struct {
    orig_term: posix.system.termios,
    screenrows: usize,
    screencols: usize,
};
var state: EditorState = undefined;

inline fn ctrl_key(k: u8) u8 {
    return k & 0x1f;
}

pub fn enable_raw_mode(handle: posix.fd_t) !void {
    state.orig_term = try posix.tcgetattr(handle);
    var term = state.orig_term;
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
    term.cflag.CSIZE = posix.CSIZE.CS8;
    term.cc[@intFromEnum(posix.V.MIN)] = 0;
    term.cc[@intFromEnum(posix.V.TIME)] = 1;
    try posix.tcsetattr(handle, .NOW, term);
}
pub fn disable_raw_mode(handle: posix.fd_t) !void {
    try posix.tcsetattr(handle, .NOW, state.orig_term);
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

fn editor_refresh_screen(writer: *const std.io.AnyWriter) !void {
    try writer.writeAll("\x1b[2J");
    try writer.writeAll("\x1b[H");
    try editor_draw_rows(writer);
    try writer.writeAll("\x1b[H");
}

fn editor_draw_rows(writer: *const std.io.AnyWriter) !void {
    for (0..state.screenrows) |row| {
        try writer.writeAll("~");
        if (row != state.screenrows - 1) {
            try writer.writeAll("\r\n");
        }
    }
}

// Next step:
// https://viewsourcecode.org/snaptoken/kilo/03.rawInputAndOutput.html#window-size-the-hard-way
fn get_window_size() [2]usize {
    var ws: posix.winsize = undefined;
    const err = std.os.linux.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (posix.errno(err) == .SUCCESS) {
        return .{ ws.row, ws.col };
    } else {
        // In the original, we quit, but I want to return some default size.
        return .{ 25, 80 };
    }
}

fn init_editor() void {
    const ws = get_window_size();
    state.screenrows = ws[0];
    state.screencols = ws[1];
}

pub fn main() !void {
    const stdin = std.io.getStdIn();
    const reader = stdin.reader().any();
    const writer = std.io.getStdOut().writer().any();

    const handle = stdin.handle;
    try enable_raw_mode(handle);
    init_editor();
    defer disable_raw_mode(handle) catch |err| {
        std.debug.print("Failed to disable raw mode: {}", .{err});
    };

    // I am not sure whether this will clear the error message or not.
    errdefer editor_refresh_screen(&writer) catch |err| {
        std.debug.print("Failed to clear screen: {}", .{err});
    };

    while (true) {
        try editor_refresh_screen(&writer);
        if (!try editor_process_keypress(&reader)) {
            break;
        }
    }
}
