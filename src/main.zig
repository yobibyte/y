const std = @import("std");
const posix = std.posix;

// In the original tutorial, this is a enum.
// But I do not want to create an element for every char.
// Maybe there is a better way, but for now I'll keep it as is.
// Give the keys values above char levels to use actual chars to edit text.
const KEY_UP = 1000;
const KEY_DOWN = 1001;
const KEY_LEFT = 1002;
const KEY_RIGHT = 1003;
const KEY_PGUP = 1004;
const KEY_PGDOWN = 1005;
const KEY_HOME = 1006;
const KEY_END = 1007;

const zon: struct {
    name: enum { y },
    version: []const u8,
    fingerprint: u64,
    minimum_zig_version: []const u8,
    paths: []const []const u8,
} = @import("zon_mod");

const welcome_msg = "yobibyte's text editor, version " ++ zon.version ++ ".";

const String = struct {
    data: []const u8,
    allocator: std.mem.Allocator,

    fn append(self: *String, other: []const u8) !void {
        const new_data = try self.allocator.alloc(u8, self.data.len + other.len);
        std.mem.copyForwards(u8, new_data[0..self.data.len], self.data);
        std.mem.copyForwards(u8, new_data[self.data.len..], other);
        self.allocator.free(self.data);
        self.data = new_data;
    }

    fn free(self: *String) void {
        self.allocator.free(self.data);
    }
};

const EditorState = struct {
    allocator: std.mem.Allocator,
    orig_term: posix.system.termios,
    screenrows: usize,
    screencols: usize,
    cx: usize,
    cy: usize,
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

fn editor_read_key(reader: *const std.io.AnyReader) !u16 {
    const c = reader.readByte() catch |err| switch (err) {
        error.EndOfStream => return 0,
        else => return err,
    };

    if (c == '\x1b') {
        const c1 = reader.readByte() catch return '\x1b';
        if (c1 == '[') {
            const c2 = reader.readByte() catch return '\x1b';
            switch (c2) {
                '1'...'9' => {
                    const c3 = reader.readByte() catch return '\x1b';
                    if (c3 == '~') {
                        switch (c2) {
                            '1' => return KEY_HOME,
                            '4' => return KEY_END,
                            '5' => return KEY_PGUP,
                            '6' => return KEY_PGDOWN,
                            '7' => return KEY_HOME,
                            '8' => return KEY_END,
                            else => {
                                std.debug.print("Only 5 or 6 are possible.", .{});
                            },
                        }
                    }
                },
                'A' => return KEY_UP,
                'B' => return KEY_DOWN,
                'C' => return KEY_RIGHT,
                'D' => return KEY_LEFT,
                'H' => return KEY_HOME,
                'F' => return KEY_END,
                else => {},
            }
        } else if (c1 == 'O') {
            switch (c1) {
                'H' => return KEY_HOME,
                'F' => return KEY_END,
                else => {},
            }
        }
        return '\x1b';
    } else {
        return c;
    }
}

fn editor_process_keypress(reader: *const std.io.AnyReader) !bool {
    const c = try editor_read_key(reader);
    switch (c) {
        ctrl_key('q') => return false,
        KEY_UP, KEY_DOWN, KEY_RIGHT, KEY_LEFT => editor_move_cursor(c),
        KEY_PGUP, KEY_PGDOWN => {
            for (0..state.screenrows) |_| {
                editor_move_cursor(if (c == KEY_PGUP) KEY_UP else KEY_DOWN);
            }
        },
        KEY_HOME => {
            state.cy = 0;
        },
        KEY_END => {
            state.cy = state.screencols - 1;
        },
        else => {},
    }
    return true;
}

fn editor_refresh_screen(writer: *const std.io.AnyWriter) !void {
    var str_buf = String{ .data = "", .allocator = state.allocator };
    //TODO: Does this release the memory in the ArenaAllocator?
    defer str_buf.free();

    try str_buf.append("\x1b[?25l");
    try str_buf.append("\x1b[H");
    try editor_draw_rows(&str_buf);
    var buf: [20]u8 = undefined;
    const escape_code = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ state.cx + 1, state.cy + 1 });
    try str_buf.append(escape_code);

    try str_buf.append("\x1b[?25h");
    try writer.writeAll(str_buf.data);
}

fn editor_draw_rows(str_buffer: *String) !void {
    for (0..state.screenrows) |row| {
        // Erase in line, by default, erases everything to the right of cursor.
        if (row == state.screenrows / 3) {
            if (state.screencols - welcome_msg.len >= 0) {
                const padding = (state.screencols - welcome_msg.len) / 2;
                if (padding > 0) {
                    try str_buffer.append("~");
                }
                for (0..padding - 1) |_| {
                    try str_buffer.append(" ");
                }
                try str_buffer.append(welcome_msg);
            }
        } else {
            try str_buffer.append("~");
        }
        try str_buffer.append("\x1b[K");
        if (row != state.screenrows - 1) {
            try str_buffer.append("\r\n");
        }
    }
}

fn editor_move_cursor(key: u16) void {
    switch (key) {
        KEY_LEFT => {
            if (state.cy > 0) {
                state.cy -= 1;
            }
        },
        KEY_DOWN => {
            if (state.cx < state.screenrows - 1) {
                state.cx += 1;
            }
        },
        KEY_UP => {
            if (state.cx > 0) {
                state.cx -= 1;
            }
        },
        KEY_RIGHT => {
            if (state.cy < state.screencols - 1) {
                state.cy += 1;
            }
        },
        else => return,
    }
}

fn get_cursor_position(writer: *const std.io.AnyWriter) ![2]usize {
    try writer.writeAll("\x1b[6n");
    const stdin = std.io.getStdIn();
    const reader = stdin.reader().any();

    //[2..] because we get an escape sequence coming back.
    // It looks like 27[rows;colsR, we need to parse it.
    var buf: [32]u8 = undefined;
    const line = try reader.readUntilDelimiterOrEof(&buf, 'R') orelse "";
    var tokenizer = std.mem.splitScalar(u8, line[2..], ';');

    // Have some default values in case this thing fails.
    const rows = try std.fmt.parseInt(usize, tokenizer.next() orelse "25", 10);
    const cols = try std.fmt.parseInt(usize, tokenizer.next() orelse "80", 10);

    return .{ rows, cols };
}

fn get_window_size(writer: *const std.io.AnyWriter) ![2]usize {
    var ws: posix.winsize = undefined;
    const err = std.os.linux.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws));

    if (posix.errno(err) == .SUCCESS) {
        return .{ ws.row, ws.col };
    } else {
        // If ioctl failed, we will move cursor to the bottom right position and get its coordinates.
        try writer.writeAll("\x1b[999C\x1b[999B");
        return get_cursor_position(writer);
    }
}

fn init_editor(writer: *const std.io.AnyWriter, allocator: std.mem.Allocator) !void {
    const ws = try get_window_size(writer);
    state.screenrows = ws[0];
    state.screencols = ws[1];
    state.allocator = allocator;
    state.cx = 0;
    state.cy = 0;
}

pub fn main() !void {
    const stdin = std.io.getStdIn();
    const reader = stdin.reader().any();
    const writer = std.io.getStdOut().writer().any();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const handle = stdin.handle;
    try enable_raw_mode(handle);
    try init_editor(&writer, arena.allocator());
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
