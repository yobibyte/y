const std = @import("std");
const config = @import("config.zig");
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
const KEY_DEL = 1008;

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

const Row = struct {
    content: []u8,
    render: []u8,

    fn init(content: []u8) !*Row {
        var self = try state.allocator.create(Row);
        self.content = content;
        var tabs: usize = 0;
        for (content) |c| {
            if (c == '\t') {
                tabs += 1;
            }
        }
        // We already have 1 byte in the content, subtract from the width.
        // This is the maximum number of memory we'll use.
        self.render = try state.allocator.alloc(u8, content.len + tabs * (config.TAB_WIDTH - 1));
        var render_idx: usize = 0;
        for (content) |c| {
            if (c == '\t') {
                self.render[render_idx] = ' ';
                render_idx += 1;
                while (render_idx % config.TAB_WIDTH != 0) {
                    self.render[render_idx] = ' ';
                    render_idx += 1;
                }
            } else {
                self.render[render_idx] = c;
                render_idx += 1;
            }
        }
        self.render = self.render[0..render_idx];

        return self;
    }

    // I am not sure if I want to support tabs at all.
    // I can prob just get rid of this functionality and always render tabs as spaces.
    fn cxToRx(self: *Row, cx: usize) usize {
        var rx: usize = 0;

        for (self.content[0..cx]) |c| {
            if (c == '\t') {
                rx += (config.TAB_WIDTH - 1) - (rx % config.TAB_WIDTH);
            }
            rx+=1;
        }

        return rx;
    }
};

const EditorState = struct {
    allocator: std.mem.Allocator,
    orig_term: posix.system.termios,
    screenrows: usize,
    screencols: usize,
    cx: usize,
    cy: usize, // y coordinate in the file frame of reference.
    rx: usize, // render x coordinate.
    rows: std.array_list.Managed(*Row),
    rowoffset: usize,
    coloffset: usize,
};
var state: EditorState = undefined;

inline fn ctrlKey(k: u8) u8 {
    return k & 0x1f;
}

pub fn enableRawMode(handle: posix.fd_t) !void {
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
pub fn disableRawMode(handle: posix.fd_t) !void {
    try posix.tcsetattr(handle, .NOW, state.orig_term);
}

fn editorReadKey(reader: *std.fs.File.Reader) !u16 {
    var oldreader = reader.interface.adaptToOldInterface();
    const c = oldreader.readByte() catch |err| switch (err) {
        error.EndOfStream => return 0,
        else => return err,
    };

    if (c == '\x1b') {
        const c1 = oldreader.readByte() catch return '\x1b';
        if (c1 == '[') {
            const c2 = oldreader.readByte() catch return '\x1b';
            switch (c2) {
                '1'...'9' => {
                    const c3 = oldreader.readByte() catch return '\x1b';
                    if (c3 == '~') {
                        switch (c2) {
                            '1' => return KEY_HOME,
                            '3' => return KEY_DEL,
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

fn editorProcessKeypress(reader: *std.fs.File.Reader) !bool {
    const c = try editorReadKey(reader);
    switch (c) {
        ctrlKey('q') => return false,
        KEY_UP, KEY_DOWN, KEY_RIGHT, KEY_LEFT => editorMoveCursor(c),
        KEY_PGUP, KEY_PGDOWN => {
            if (c == KEY_PGUP) {
                state.cy = state.rowoffset;
            } else {
                state.cy = state.rowoffset + state.screenrows - 1;
                if (state.cy > state.rows.items.len) {
                    state.cy = state.rows.items.len;
                }
            }
            for (0..state.screenrows) |_| {
                editorMoveCursor(if (c == KEY_PGUP) KEY_UP else KEY_DOWN);
            }
        },
        KEY_HOME => {
            state.cx = 0;
        },
        // FIXME: if there's a tab, we do not properly jump to line end.
        KEY_END => {
            if (state.cy < state.rows.items.len) {
                state.cx = state.rows.items[state.cy].content.len;
            }
        },

        else => {},
    }
    return true;
}

fn editorScroll() void {
    state.rx = 0;
    if (state.cy < state.rows.items.len) {
        state.rx = state.rows.items[state.cy].cxToRx(state.cx);
        std.debug.print("{d}, {d}\n", .{state.cx, state.rx});
    }

    if (state.cy < state.rowoffset) {
        state.rowoffset = state.cy;
    }
    if (state.cy >= state.rowoffset + state.screenrows) {
        state.rowoffset = state.cy - state.screenrows + 1;
    }
    if (state.rx < state.coloffset) {
        state.coloffset = state.rx;
    }
    if (state.rx >= state.coloffset + state.screencols) {
        state.coloffset = state.rx - state.screencols + 1;
    }
}
fn editorRefreshScreen(writer: *const std.fs.File) !void {
    std.debug.print("YO {d}", .{state.rows.items.len});
    editorScroll();
    var str_buf = String{ .data = "", .allocator = state.allocator };
    //TODO: Does this release the memory in the ArenaAllocator?
    defer str_buf.free();

    try str_buf.append("\x1b[?25l");
    try str_buf.append("\x1b[H");
    try editorDrawRows(&str_buf);
    var buf: [20]u8 = undefined;
    const escape_code = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ state.cy - state.rowoffset + 1, state.rx - state.coloffset + 1 });
    try str_buf.append(escape_code);

    try str_buf.append("\x1b[?25h");
    try writer.writeAll(str_buf.data);
}

fn editorDrawRows(str_buffer: *String) !void {
    for (0..state.screenrows) |row| {
        const filerow = state.rowoffset + row;
        // Erase in line, by default, erases everything to the right of cursor.
        // TODO: I wonder how these .len calls would behave with utf-8 chars.
        if (filerow >= state.rows.items.len) {
            if (state.rows.items.len == 0 and row == state.screenrows / 3) {
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
        } else {
            const crow = state.rows.items[filerow].render;
            if (crow.len >= state.coloffset) {
                var maxlen = crow.len - state.coloffset;
                if (maxlen > state.screencols) {
                    maxlen = state.screencols;
                }
                try str_buffer.append(crow[state.coloffset .. state.coloffset + maxlen]);
            }
        }
        try str_buffer.append("\x1b[K");
        if (row != state.screenrows - 1) {
            try str_buffer.append("\r\n");
        }
    }
}

fn editorMoveCursor(key: u16) void {
    switch (key) {
        KEY_LEFT => {
            if (state.cx > 0) {
                state.cx -= 1;
            }
        },
        KEY_DOWN => {
            if (state.cy < state.rows.items.len) {
                state.cy += 1;
            }
        },
        KEY_UP => {
            if (state.cy > 0) {
                state.cy -= 1;
            }
        },
        KEY_RIGHT => {
            if (state.cy < state.rows.items.len) {
                if (state.cx < state.rows.items[state.cy].content.len) {
                    state.cx += 1;
                }
            }
        },
        else => return,
    }
    const rowlen = if (state.cy < state.rows.items.len) state.rows.items[state.cy].content.len else 0;
    if (state.cx > rowlen) {
        state.cx = rowlen;
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

fn getWindowSize(writer: *const std.fs.File) ![2]usize {
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

fn initEditor(writer: *const std.fs.File, allocator: std.mem.Allocator) !void {
    const ws = try getWindowSize(writer);
    state.screenrows = ws[0];
    state.screencols = ws[1];
    state.allocator = allocator;
    state.cx = 0;
    state.rx = 0;
    state.cy = 0;
    state.rows = std.array_list.Managed(*Row).init(allocator);
    state.rowoffset = 0;
    state.coloffset = 0;
}

fn editorOpen(fname: []const u8) !void {
    std.debug.print("{s}", .{fname});
    const file = try std.fs.cwd().openFile(fname, .{ .mode = .read_only });
    defer file.close();

    // Wrap the file in a buffered reader
    var stdin_buffer: [1024]u8 = undefined;
    var reader = file.reader(&stdin_buffer);

    while (true) {
        const line = reader.interface.takeDelimiterExclusive('\n') catch |err| {
            switch (err) {
                error.EndOfStream => break,
                else => return err,
            }
        };
        const content = try state.allocator.dupe(u8, line);
        try state.rows.append(try Row.init(content));
    }
}

pub fn main() !void {
    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();
    var stdin_buffer: [1024]u8 = undefined;
    var reader = stdin.reader(&stdin_buffer);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const handle = stdin.handle;
    try enableRawMode(handle);
    try initEditor(&stdout, arena.allocator());
    if (std.os.argv.len > 1) {
        try editorOpen(std.mem.span(std.os.argv[1]));
    }
    defer disableRawMode(handle) catch |err| {
        std.debug.print("Failed to disable raw mode: {}", .{err});
    };

    // I am not sure whether this will clear the error message or not.
    errdefer editorRefreshScreen(&stdout) catch |err| {
        std.debug.print("Failed to clear screen: {}", .{err});
    };

    while (true) {
        try editorRefreshScreen(&stdout);
        // editorScroll();
        if (!try editorProcessKeypress(&reader)) {
            break;
        }
    }
}
