//
//                     (/, .#
//                  ((//**,#((/#%.%%#//
//              &#%&#((%&%########((/,,,/
//           (#(@#(%%%%&&&%%%%######(((//,
//          %%%%&%%%%%#&&&%&%%#%%#####(((///
//       &&&&%#&#//&&&@@&&&&%%####((((((((//*,
//      %@&@&%&@(/(&&&@@&&&%%%###((((((((((////
//    .%&@&#%&(#%(/%&@@@@@&&%%%###((((((((/////*//
//   &&&@%(&&*#(#/%&@@@@@@&&%%%###((((((((((////*(*
//  #%&&%%#&/(/%#(@@@@@@&&%%%##(((((/((((///////,//
//  #%%%(#@(#(/*(@@@@@%%%%(/***//((/(((///**//(,**,*
//  &&&#%%@%((//&@@@%%%/@%(/(***/##(((**/////*/,,,*     - - - - - - - - - - - -
//  #&@%%#(##(#%@@@&%(#&%#/(((/(#&&%(*,////**,//(///   | Best text editor ever! |
// @&%#&@#*((*&@@@&&&&%%&#(((%&@@@@&(((/(//((((/((*     - - - - - - - - - - - -
//  %#&%%(&((#&@@&&&&%###%%%##@@&%(//**(##(((((/*,     /
//   &%#/(%&%@%@@&&&&%%%%#(((**,,,/**,**/((#((//      /
//    ###&@@&&%&&@@&&&%%#(((##%&&%(/##(((/(((/(/     /
//     /(&#(#@%&%(%&%#&##(&&@&&%(#((#/((((((/((*(   /
//       @&@&@(((##@&&%#&@&%#/*.......*,,/(/(/(//  /
//       &&&&@@&(#(@@#@&@##(*.*//////// .(((((((((
//       @&&#&@@###%##&##(,*((((##((((((/*(//((***
//        ,/&%#@(/(#&&&%#///((((##((///(/*//((((*
//         (#&@((,%%&&%%#((/((/#(///(**(/((*//((/
//       ,&&%&%#(@%&/&#((#(//(/(*/(#&%((**//((//
//      &&&&&&%%@@*/*%(##(((##(/&(%&/,(((/((**(
//      %&&&&&%%%@##*%##(#####&&(((,((((/(((((
//      &&&&&&&&&%%%&####((##&##(**(/*/((/(/,
//      %&&&&&%%%#%###(#%(((##(*//.*/(*,*/(/,
//       *%&%%#%#%%%%&(%%///,*%((((/(((,,,.(*
//         (%#(/%#%&%#%%/,*//,(#%(/(/(((.((/
//            /#%&%#%##////(#%(@%*,,*/*/.(
//                 /(/#(((/*/#****/*,/*.

const std = @import("std");
const config = @import("config.zig");
const row = @import("row.zig");
const posix = std.posix;

// In the original tutorial, this is a enum.
// But I do not want to create an element for every char.
// Maybe there is a better way, but for now I'll keep it as is.
// Give the keys values above char levels to use actual chars to edit text.
const KEY_PROMPT = 32; // space
const KEY_BACKSPACE = 127;
const KEY_UP = 1000;
const KEY_DOWN = 1001;
const KEY_LEFT = 1002;
const KEY_RIGHT = 1003;
const KEY_PGUP = 1004;
const KEY_PGDOWN = 1005;
const KEY_HOME = 1006;
const KEY_END = 1007;
const KEY_DEL = 1008;

const Mode = enum {
    normal,
    insert,
};

const zon: struct {
    name: enum { y },
    version: []const u8,
    fingerprint: u64,
    minimum_zig_version: []const u8,
    paths: []const []const u8,
} = @import("zon_mod");

const welcome_msg = "yobibyte's text editor, version " ++ zon.version ++ ".";

const String = struct {
    data: []u8,
    allocator: std.mem.Allocator,
    len: usize,

    fn init(size: usize, allocator: std.mem.Allocator) !*String {
        var self = try allocator.create(String);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.data = try self.allocator.alloc(u8, size);
        self.len = 0; // We allocate memory, but do not fill it yet.
        return self;
    }

    fn append(self: *String, other: []const u8) !void {
        const target_size = self.len + other.len;
        if (self.data.len < target_size) {
            // If not enough memory in the buffer, increase the size of it.
            const newsize = @max(target_size, self.data.len * 2);
            const new_data = try self.allocator.alloc(u8, newsize);
            if (self.len > 0) {
                @memcpy(new_data[0..self.len], self.data[0..self.len]);
            }
            @memcpy(new_data[self.len..][0..other.len], other);
            self.allocator.free(self.data);
            self.data = new_data;
        } else {
            @memcpy(self.data[self.len..target_size], other);
        }
        self.len = target_size;
    }

    fn content(self: *String) []u8 {
        return self.data[0..self.len];
    }

    fn deinit(self: *String) void {
        self.allocator.free(self.data);
        self.allocator.destroy(self);
    }
};
const Buffer = struct {
    allocator: std.mem.Allocator,
    orig_term: posix.system.termios,
    screenrows: usize,
    screencols: usize,
    cx: usize,
    cy: usize, // y coordinate in the file frame of reference.
    rx: usize, // render x coordinate.
    rows: std.array_list.Managed(*row.Row),
    rowoffset: usize,
    coloffset: usize,
    filename: ?[]const u8,
    statusmsg: []const u8,
    statusmsg_time: i64,
    // Can do with a bool now, but probably will be useful for tracking undo.
    // Probably, with the undo file, we can make it signed, but I will change it later.
    dirty: u64,
    confirm_to_quit: bool, // if set, quit without confirmation, reset when pressed Ctrl+Q once.
    stdout: *const std.fs.File,
    reader: *std.fs.File.Reader,
    comment_chars: []const u8,

    fn rowsToString(self: *Buffer) ![]u8 {
        var total_len: usize = 0;
        for (self.rows.items) |crow| {
            // 1 for the newline symbol.
            total_len += crow.content.len + 1;
        }
        const buf = try state.allocator.alloc(u8, total_len);
        var bytes_written: usize = 0;
        for (self.rows.items) |crow| {
            // stdlib docs say this function is deprecated.
            // TODO: rewrite to use @memmove.
            if (crow.content.len > 0) {
                std.mem.copyForwards(u8, buf[bytes_written .. bytes_written + crow.content.len], crow.content);
            }
            bytes_written += crow.content.len;
            buf[bytes_written] = '\n';
            bytes_written += 1;
        }
        return buf;
    }

    fn reset(self: *Buffer, writer: *const std.fs.File, reader: *std.fs.File.Reader, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        self.cx = 0;
        self.rx = 0;
        self.cy = 0;
        self.rows = std.array_list.Managed(*row.Row).init(allocator);
        self.rowoffset = 0;
        self.coloffset = 0;
        const ws = try getWindowSize(writer);
        self.screenrows = ws[0] - 2;
        self.screencols = ws[1];
        self.filename = null;
        self.statusmsg = "";
        self.statusmsg_time = 0;
        self.dirty = 0;
        self.confirm_to_quit = true;
        self.stdout = writer;
        self.reader = reader;
        self.comment_chars = "//";
    }

    fn deinit(self: *Buffer) void {
        for (self.rows.items) |crow| {
            crow.deinit();
        }
        self.rows.deinit();
        if (self.filename) |fname| {
            self.allocator.free(fname);
        }
        state.allocator.free(state.statusmsg);
    }
};
pub var state: Buffer = undefined;

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
pub fn disableRawMode(handle: posix.fd_t, writer: *const std.fs.File) !void {
    // Clear screen and move cursort to the top left.
    try writer.writeAll("\x1b[H\x1b[2J");
    try posix.tcsetattr(handle, .NOW, state.orig_term);
}

fn editorReadKey() !u16 {
    var oldreader = state.reader.interface.adaptToOldInterface();
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
                    // There is prob a method to read until the end of stream in the stdlib, but we will need to move to a new API soon, we will do it then.
                    while (true) {
                        _ = oldreader.readByte() catch return '\x1b';
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

fn editorQuit() !bool {
    if (state.dirty > 0 and state.confirm_to_quit) {
        state.confirm_to_quit = false;
        try editorSetStatusMessage("You have unsaved changes. Use the quit command again if you still want to quit.");
        return true;
    }
    return false;
}

fn editorCommentLine() !void {
    var to_comment = true;
    if (state.rows.items[state.cy].content.len >= state.comment_chars.len) {
        to_comment = !std.mem.startsWith(u8, state.rows.items[state.cy].content, state.comment_chars);
    }
    for (state.comment_chars, 0..) |cs, i| {
        if (to_comment) {
            try state.rows.items[state.cy].insertChar(cs, i);
            state.cx += 1;
        } else {
            state.rows.items[state.cy].delChar(0);
            if (state.cx > 0) {
                state.cx -= 1;
            }
        }
    }
    try state.rows.items[state.cy].update();
    state.dirty += 1;
}

fn editorScroll() void {
    state.rx = 0;
    if (state.cy < state.rows.items.len) {
        state.rx = state.rows.items[state.cy].cxToRx(state.cx);
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
fn editorDrawRows(str_buffer: *String) !void {
    for (0..state.screenrows) |crow| {
        const filerow = state.rowoffset + crow;
        // Erase in line, by default, erases everything to the right of cursor.
        if (filerow >= state.rows.items.len) {
            if (state.rows.items.len == 0 and crow == state.screenrows / 3) {
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
            const offset_row = state.rows.items[filerow].render;
            if (offset_row.len >= state.coloffset) {
                var maxlen = offset_row.len - state.coloffset;
                if (maxlen > state.screencols) {
                    maxlen = state.screencols;
                }
                try str_buffer.append(offset_row[state.coloffset .. state.coloffset + maxlen]);
            }
        }
        try str_buffer.append("\x1b[K");
        try str_buffer.append("\r\n");
    }
}

fn editorDrawMessageBar(str_buffer: *String) !void {
    try str_buffer.append("\x1b[K");
    var msg = state.statusmsg;
    if (state.statusmsg.len > state.screencols) {
        msg = state.statusmsg[0..state.screencols];
    }
    if (state.statusmsg.len > 0 and std.time.timestamp() - state.statusmsg_time < config.STATUS_MSG_DURATION_SEC) {
        try str_buffer.append(state.statusmsg);
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

fn editorSetCommentChars() void {
    const fname = state.filename orelse return;
    if (std.mem.endsWith(u8, fname, ".py")) {
        state.comment_chars = "#";
    }
}

fn editorInsertRow(at: usize, line: []u8) !void {
    if (at > state.rows.items.len) {
        return;
    }
    try state.rows.insert(at, try row.Row.init(line, state.allocator));

    try state.rows.items[at].update();
    state.dirty += 1;
}

fn editorInsertChar(c: u8) !void {
    if (state.cy == state.rows.items.len) {
        try editorInsertRow(state.cy, "");
    }
    try state.rows.items[state.cy].insertChar(c, state.cx);
    state.cx += 1;
}

fn editorSetStatusMessage(msg: []const u8) !void {
    // There is some formatting magic in the tutorial version of this.
    // Would probably be nicer not to format string before every message, but it also
    // simpler to some extent.
    state.allocator.free(state.statusmsg);
    state.statusmsg = try state.allocator.dupe(u8, msg);
    state.statusmsg_time = std.time.timestamp();
}

fn editorDelCharToLeft() !void {
    if (state.cy == state.rows.items.len) {
        return;
    }
    if (state.cx == 0 and state.cy == 0) {
        return;
    }
    // How can it be smaller than zero?
    var crow = state.rows.items[state.cy];
    if (state.cx > 0) {
        crow.delChar(state.cx - 1);
        state.cx -= 1;
    } else {
        // Move cursor to the joint of two new rows.
        var prev_row = state.rows.items[state.cy - 1];
        state.cx = prev_row.content.len;
        // Join the two rows.
        try prev_row.append(state.rows.items[state.cy].content);
        editorDelRow(state.cy); // Remove the current row
        state.cy -= 1; // Move cursor up.
    }
    try crow.update();
    state.dirty += 1;
}

fn editorDelRow(at: usize) void {
    if (at >= state.rows.items.len) {
        return;
    }
    const crow = state.rows.orderedRemove(at);
    crow.deinit();
    state.dirty += 1;
}

fn editorInsertNewLine() !void {
    if (state.cx == 0) {
        try editorInsertRow(state.cy, "");
    } else {
        var crow = state.rows.items[state.cy];
        try editorInsertRow(state.cy + 1, crow.content[state.cx..]);
        crow.content = crow.content[0..state.cx];
        try crow.update();
    }
    state.cy += 1;
    state.cx = 0;
    state.dirty += 1;
}

const Editor = struct {
    allocator: std.mem.Allocator,
    stdin: std.fs.File,
    stdout: std.fs.File,
    handle: std.posix.fd_t,
    reader: std.fs.File.Reader,
    stdin_buffer: [1024]u8,
    state: *Buffer,
    mode: Mode,

    fn init(allocator: std.mem.Allocator) !*Editor {
        var self = try allocator.create(Editor);
        self.allocator = allocator;

        self.stdin = std.fs.File.stdin();
        self.stdout = std.fs.File.stdout();
        self.stdin_buffer = undefined;
        self.reader = self.stdin.reader(&self.stdin_buffer);
        self.handle = self.stdin.handle;

        // This is temporal. I will split the state into two parts:
        // Some of the editor-level vars will move to just Editor fields.
        // The rest, like Rows, will become buffers, and editor will keep a list (or a map) of buffers.
        self.state = &state;
        self.mode = Mode.normal;

        try enableRawMode(self.handle);
        try state.reset(&self.stdout, &self.reader, self.allocator);
        return self;
    }

    fn deinit(self: *Editor) void {
        disableRawMode(self.handle, &self.stdout) catch |err| {
            std.debug.print("Failed to restore the original terminal mode: {}", .{err});
        };
        self.state.deinit();
        self.allocator.destroy(self);
    }

    fn open(self: *Editor, fname: []const u8) !void {
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
            try editorInsertRow(self.state.rows.items.len, line);
        }
        self.state.filename = try state.allocator.dupe(u8, fname);
        editorSetCommentChars();

        // InsertRow calls above modify the dirty counter -> reset.
        self.state.dirty = 0;
    }

    fn processKeypress(self: *Editor, c: u16) !bool {
        return switch (self.mode) {
            Mode.normal => try self.processKeypressNormal(c),
            Mode.insert => try self.processKeypressInsert(c),
        };
    }

    fn processKeypressNormal(self: *Editor, c: u16) !bool {
        switch (c) {
            0 => return true, // 0 is EndOfStream.
            'h' => editorMoveCursor(KEY_LEFT),
            'j' => editorMoveCursor(KEY_DOWN),
            'k' => editorMoveCursor(KEY_UP),
            'l' => editorMoveCursor(KEY_RIGHT),
            'i' => self.mode = Mode.insert,
            's' => try self.save(),
            'q' => return editorQuit(),
            'x', KEY_DEL => {
                if (state.cy < state.rows.items.len) {
                    if (state.cx < state.rows.items[state.cy].content.len) {
                        editorMoveCursor(KEY_RIGHT);
                    }
                    try editorDelCharToLeft();
                }
            },
            'G' => state.cy = state.rows.items.len - 1,
            // Example of using a command prompt.
            KEY_PROMPT => {
                const maybe_cmd = try self.editorPrompt(":");
                if (maybe_cmd) |cmd| {
                    defer state.allocator.free(cmd);
                    if (std.mem.eql(u8, cmd, "c")) {
                        try editorCommentLine();
                    } else {
                        const number = std.fmt.parseInt(usize, cmd, 10) catch 0;
                        if (number > 0 and number <= state.rows.items.len) {
                            state.cy = number - 1;
                        }
                    }
                }
            },
            else => {
                self.mode = Mode.normal;
            },
        }

        state.confirm_to_quit = true;
        return true;
    }

    fn processKeypressInsert(self: *Editor, c: u16) !bool {
        switch (c) {
            0 => return true, // 0 is EndOfStream.
            '\r' => try editorInsertNewLine(),
            ctrlKey('q') => return editorQuit(),
            KEY_UP, KEY_DOWN, KEY_RIGHT, KEY_LEFT => editorMoveCursor(c),
            KEY_BACKSPACE, KEY_DEL, ctrlKey('h') => {
                if (c == KEY_DEL) {
                    // We should be joining the two rows in here in the insert mode.
                    if (state.cy < state.rows.items.len) {
                        if (state.cx == state.rows.items[state.cy].content.len) {
                            state.cx = 0;
                            editorMoveCursor(KEY_DOWN);
                        } else {
                            editorMoveCursor(KEY_RIGHT);
                        }
                        try editorDelCharToLeft();
                    }
                } else {
                    try editorDelCharToLeft();
                }
            },
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
            ctrlKey('s') => try self.save(),
            KEY_HOME => {
                state.cx = 0;
            },
            KEY_END => {
                if (state.cy < state.rows.items.len) {
                    state.cx = state.rows.items[state.cy].content.len;
                }
            },

            ctrlKey('l'), '\x1b' => {
                self.mode = Mode.normal;
            },
            else => {
                const casted_char = std.math.cast(u8, c) orelse return error.ValueTooBig;
                if (!std.ascii.isControl(casted_char)) {
                    try editorInsertChar(casted_char);
                }
            },
        }
        // Reset confirmation flag when any other key than Ctrl+q was typed.
        state.confirm_to_quit = true;
        return true;
    }

    fn drawStatusBar(self: *Editor, str_buffer: *String) !void {
        try str_buffer.append("\x1b[7m");

        // Reserve space for lines.
        var lbuffer: [100]u8 = undefined;
        const lines = try std.fmt.bufPrint(&lbuffer, " {s} {d}/{d}", .{ @tagName(self.mode), state.cy + 1, state.rows.items.len });

        const mod_string = if (state.dirty > 0) " (modified)" else "";
        const emptyspots = state.screencols - lines.len - mod_string.len;

        // Should we truncate from the left? What does vim do?
        var fname = state.filename orelse "[no name]";
        if (fname.len > emptyspots) {
            fname = fname[0..emptyspots];
        }
        try str_buffer.append(fname);
        try str_buffer.append(mod_string);

        const nspaces = emptyspots - fname.len;
        if (nspaces > 0) {
            const spaces_mem = try state.allocator.alloc(u8, nspaces);
            @memset(spaces_mem, ' ');
            try str_buffer.append(spaces_mem);
            state.allocator.free(spaces_mem);
        }

        try str_buffer.append(lines);
        try str_buffer.append("\x1b[m");
        try str_buffer.append("\r\n");
    }

    fn refreshScreen(self: *Editor) !void {
        editorScroll();
        // TODO: Make this bigger?
        var str_buf = try String.init(80, state.allocator);
        defer str_buf.deinit();

        try str_buf.append("\x1b[?25l");
        try str_buf.append("\x1b[H");
        try editorDrawRows(str_buf);
        try self.drawStatusBar(str_buf);
        try editorDrawMessageBar(str_buf);
        var buf: [20]u8 = undefined;
        const escape_code = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ state.cy - state.rowoffset + 1, state.rx - state.coloffset + 1 });
        try str_buf.append(escape_code);

        try str_buf.append("\x1b[?25h");
        try state.stdout.writeAll(str_buf.content());
    }

    fn editorPrompt(self: *Editor, prompt: []const u8) !?[]u8 {
        var command_buf = try state.allocator.alloc(u8, 80);
        var command_buf_len: usize = prompt.len;
        const promptlen = prompt.len;
        std.mem.copyForwards(u8, command_buf[0..promptlen], prompt);

        while (true) {
            try editorSetStatusMessage(command_buf[0..command_buf_len]);
            try self.refreshScreen();

            const c: u16 = try editorReadKey();

            if (c == KEY_DEL or c == ctrlKey('h') or c == KEY_BACKSPACE) {
                // we should be able to move around here and DEL should behave differently from BACKSPACE.
                if (command_buf_len != promptlen) {
                    command_buf_len -= 1;
                }
            } else if (c == '\x1b') {
                try editorSetStatusMessage("");
                return null;
            } else if (c == '\r') {
                if (command_buf_len != 0) {
                    try editorSetStatusMessage("");
                    const new_buffer = try state.allocator.alloc(u8, command_buf_len - promptlen);
                    @memcpy(new_buffer, command_buf[promptlen..command_buf_len]);
                    state.allocator.free(command_buf);
                    return new_buffer;
                }
            } else if (c > 0 and c < 128) {
                const casted_char = std.math.cast(u8, c) orelse return error.ValueTooBig;
                if (!std.ascii.isControl(casted_char)) {
                    const curlen = command_buf.len;
                    if (command_buf_len == curlen - 1) {
                        const new_command_buf = try state.allocator.alloc(u8, 2 * curlen);
                        std.mem.copyForwards(u8, new_command_buf[0..curlen], command_buf[0..curlen]);
                        defer state.allocator.free(command_buf);
                        command_buf = new_command_buf;
                    }
                    command_buf[command_buf_len] = casted_char;
                    command_buf_len += 1;
                }
            }
        }
    }

    // TODO: This should prob be on the buffer level.
    fn save(self: *Editor) !void {
        if (self.state.filename == null) {
            const prompt = try self.editorPrompt("Save as: ");
            if (prompt) |fname| {
                defer state.allocator.free(fname);
                state.filename = try state.allocator.dupe(u8, fname);
            }
        }
        if (state.filename) |fname| {
            editorSetCommentChars();
            const buf = try state.rowsToString();
            defer state.allocator.free(buf);
            const file = try std.fs.cwd().createFile(fname, .{ .truncate = true });
            defer file.close();

            file.writeAll(buf) catch |err| {
                var err_buf: [100]u8 = undefined;
                const failure_msg = try std.fmt.bufPrint(&err_buf, "Failed to save a file: {}", .{err});
                try editorSetStatusMessage(failure_msg);
                return;
            };
            var fmt_buf: [100]u8 = undefined;
            const success_msg = try std.fmt.bufPrint(&fmt_buf, "{d} bytes written to disk.", .{buf.len});
            try editorSetStatusMessage(success_msg);
            state.dirty = 0;
        } else {
            try editorSetStatusMessage("Save aborted.");
            return;
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer switch (gpa.deinit()) {
        .leak => std.debug.panic("Some memory leaked!", .{}),
        .ok => {},
    };

    const editor = try Editor.init(gpa.allocator());
    defer editor.deinit();

    if (std.os.argv.len > 1) {
        try editor.open(std.mem.span(std.os.argv[1]));
    }

    while (true) {
        try editor.refreshScreen();
        const c = try editorReadKey();
        const should_continue = try editor.processKeypress(c);
        if (!should_continue) {
            break;
        }
    }
}
