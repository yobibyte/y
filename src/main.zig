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

// TODO: I probably want to get rid of the arena allocator and do the memory management manually.
// An alternative, read on what people do to manage memory with the arena allocator.

const std = @import("std");
const config = @import("config.zig");
const posix = std.posix;

// In the original tutorial, this is a enum.
// But I do not want to create an element for every char.
// Maybe there is a better way, but for now I'll keep it as is.
// Give the keys values above char levels to use actual chars to edit text.
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
    allocator: *const std.mem.Allocator,

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
// TODO: move Row to a separate file.
const Row = struct {
    content: []u8,
    render: []u8,

    fn init(content: []u8) !*Row {
        var self = try state.allocator.create(Row);
        self.content = content;
        try self.update();
        return self;
    }

    fn update(self: *Row) !void {
        var tabs: usize = 0;
        for (self.content) |c| {
            if (c == '\t') {
                tabs += 1;
            }
        }
        // TODO: move render allocation to gpa instead of arena.
        // We already have 1 byte in the content, subtract from the width.
        // This is the maximum number of memory we'll use.
        self.render = try state.allocator.alloc(u8, self.content.len + tabs * (config.TAB_WIDTH - 1));
        var render_idx: usize = 0;
        for (self.content) |c| {
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
    }

    // I am not sure if I want to support tabs at all.
    // I can prob just get rid of this functionality and always render tabs as spaces.
    fn cxToRx(self: *Row, cx: usize) usize {
        var rx: usize = 0;

        for (self.content[0..cx]) |c| {
            if (c == '\t') {
                rx += (config.TAB_WIDTH - 1) - (rx % config.TAB_WIDTH);
            }
            rx += 1;
        }

        return rx;
    }

    fn insertChar(self: *Row, c: u8, at: usize) !void {
        // I am not sure why the original tutorial used an int here.
        // I will use a unsigned int here.
        const oldsize = self.content.len;
        var actual_at = at;
        if (at > oldsize) {
            actual_at = oldsize;
        }
        // I didn'make reallocate work. Figure this out.
        // Probably after switch to the gpa.
        // self.content = state.allocator.reallocate(self.content, oldsize+1);

        const new_content = try state.allocator.alloc(u8, oldsize + 1);

        if (actual_at > 0) {
            std.mem.copyForwards(u8, new_content[0..actual_at], self.content[0..actual_at]);
        }
        new_content[actual_at] = c;
        if (actual_at < oldsize) {
            std.mem.copyForwards(u8, new_content[actual_at + 1 ..], self.content[actual_at..]);
        }
        state.allocator.free(self.content);
        self.content = new_content;

        try self.update();
        state.dirty += 1;
    }

    pub fn delChar(self: *Row, at: usize) void {
        const rowlen = self.content.len;
        if (at >= rowlen) {
            return;
        }
        std.mem.copyForwards(u8, self.content[at..], self.content[at + 1 .. rowlen]);
        self.content = self.content[0 .. rowlen - 1];
    }

    pub fn append(self: *Row, chunk: []u8) !void {
        const new_content = try state.allocator.alloc(u8, self.content.len + chunk.len);
        std.mem.copyForwards(u8, new_content[0..self.content.len], self.content);
        std.mem.copyForwards(u8, new_content[self.content.len..], chunk);
        // TODO: be careful when using gpa.
        state.allocator.free(self.content);
        self.content = new_content;

        try self.update();
        state.dirty += 1;
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
    filename: ?[]const u8,
    statusmsg: []const u8,
    statusmsg_time: i64,
    // Can do with a bool now, but probably will be useful for tracking undo.
    // Probably, with the undo file, we can make it signed, but I will change it later.
    dirty: u64,
    // TODO: Right now, if I add a char and remove it immediately, this will not reset the dirty.
    // How do we address those?
    confirm_to_quit: bool, // if set, quit without confirmation, reset when pressed Ctrl+Q once.

    fn rowsToString(self: *EditorState) ![]u8 {
        var total_len: usize = 0;
        for (self.rows.items) |row| {
            // 1 for the newline symbol.
            total_len += row.content.len + 1;
        }
        const buf = try state.allocator.alloc(u8, total_len);
        var bytes_written: usize = 0;
        for (self.rows.items) |row| {
            // stdlib docs say this function is deprecated.
            // TODO: rewrite to use @memmove.
            if (row.content.len > 0) {
                std.mem.copyForwards(u8, buf[bytes_written .. bytes_written + row.content.len], row.content);
            }
            bytes_written += row.content.len;
            buf[bytes_written] = '\n';
            bytes_written += 1;
        }
        // With the arena allocator I do not actually care who frees this.
        // But I need to figure out what to do when I move to gpa.
        return buf;
    }

    fn reset(self: *EditorState, writer: *const std.fs.File, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        self.cx = 0;
        self.rx = 0;
        self.cy = 0;
        self.rows = std.array_list.Managed(*Row).init(allocator);
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
    }
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
pub fn disableRawMode(handle: posix.fd_t, writer: *const std.fs.File) !void {
    // Clear screen and move cursort to the top left.
    try writer.writeAll("\x1b[H\x1b[2J");
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
        0 => return true, // 0 is EndOfStream.
        // TODO
        '\r' => try editorInsertNewLine(),
        ctrlKey('q') => {
            if (state.dirty > 0 and state.confirm_to_quit) {
                state.confirm_to_quit = false;
                try editorSetStatusMessage("You have unsaved changes. Press Ctrl+Q again if you still want to quit.");
                return true;
            }
            return false;
        },
        KEY_UP, KEY_DOWN, KEY_RIGHT, KEY_LEFT => editorMoveCursor(c),
        // TODO
        KEY_BACKSPACE, KEY_DEL, ctrlKey('h') => {
            if (c == KEY_DEL) {
                // TODO: this behaves incorrectly for the rightmost character now.
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
        ctrlKey('s') => try editorSave(),
        KEY_HOME => {
            state.cx = 0;
        },
        // FIXME: if there's a tab, we do not properly jump to line end.
        KEY_END => {
            if (state.cy < state.rows.items.len) {
                state.cx = state.rows.items[state.cy].content.len;
            }
        },

        // TODO
        ctrlKey('l'), '\x1b' => {},

        else => {
            const casted_char = std.math.cast(u8, c) orelse return error.ValueTooBig;
            try editorInsertChar(casted_char);
        },
    }
    // Reset confirmation flag when any other key than Ctrl+q was typed.
    state.confirm_to_quit = true;
    return true;
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
fn editorRefreshScreen(writer: *const std.fs.File, string_allocator: *const std.mem.Allocator) !void {
    editorScroll();
    var str_buf = String{ .data = "", .allocator = string_allocator };
    defer str_buf.free();

    try str_buf.append("\x1b[?25l");
    try str_buf.append("\x1b[H");
    try editorDrawRows(&str_buf);
    try editorDrawStatusBar(&str_buf);
    try editorDrawMessageBar(&str_buf);
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

fn editorDrawStatusBar(str_buffer: *String) !void {
    try str_buffer.append("\x1b[7m");

    // Reserve space for lines.
    var lbuffer: [100]u8 = undefined;
    const lines = try std.fmt.bufPrint(&lbuffer, " {d}/{d}", .{ state.cy + 1, state.rows.items.len });

    const mod_string = if (state.dirty > 0) " (modified)" else "";
    const emptyspots = state.screencols - lines.len - mod_string.len;

    // Should we truncate from the left? What does vim do?
    var fname = state.filename orelse "[no name]";
    if (fname.len > emptyspots) {
        fname = fname[0..emptyspots];
    }
    try str_buffer.append(fname);
    try str_buffer.append(mod_string);
    // TODO: Do the above properly with formatting.
    // Learn how to set the max field width dynamically in zig.

    const nspaces = emptyspots - fname.len;
    if (nspaces > 0) {
        const spaces_mem = try state.allocator.alloc(u8, nspaces);
        @memset(spaces_mem, ' ');
        try str_buffer.append(spaces_mem);
    }

    try str_buffer.append(lines);
    try str_buffer.append("\x1b[m");
    try str_buffer.append("\r\n");
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

fn editorOpen(fname: []const u8) !void {
    // FIXME, this fails
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
        try editorInsertRow(state.rows.items.len, line);
    }
    state.filename = try state.allocator.dupe(u8, fname);
    // AppendRow modifies the dirty counter -> reset.
    state.dirty = 0;
}

fn editorInsertRow(at: usize, line: []const u8) !void {
    if (at > state.rows.items.len) {
        return;
    }
    const content = try state.allocator.dupe(u8, line);
    try state.rows.insert(at, try Row.init(content));

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

fn editorSave() !void {
    // TODO: add a command to save to a filename if empty.
    const fname = state.filename orelse return;
    const buf = try state.rowsToString();
    const file = try std.fs.cwd().openFile(fname, .{ .mode = .write_only });
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
}

fn editorSetStatusMessage(msg: []const u8) !void {
    // There is some formatting magic in the tutorial version of this.
    // Would probably be nicer not to format string before every message, but it also
    // simpler to some extent.
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
    var row = state.rows.items[state.cy];
    if (state.cx > 0) {
        state.rows.items[state.cy].delChar(state.cx - 1);
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
    try row.update();
    state.dirty += 1;
}

fn editorDelRow(at: usize) void {
    if (at >= state.rows.items.len) {
        return;
    }
    // TODO: be careful! When we move to gpa, this will leak memory.
    // Free the row here.
    // This function returns the deleted element, we do not need it.
    _ = state.rows.orderedRemove(at);
    state.dirty += 1;
}

fn editorInsertNewLine() !void {
    if (state.cx == 0) {
        try editorInsertRow(state.cy, "");
    } else {
        var row = state.rows.items[state.cy];
        try editorInsertRow(state.cy + 1, row.content[state.cx..]);
        row.content = row.content[0..state.cx];
        try row.update();
    }
    state.cy += 1;
    state.cx = 0;
    state.dirty += 1;
}

pub fn main() !void {
    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();
    var stdin_buffer: [1024]u8 = undefined;
    var reader = stdin.reader(&stdin_buffer);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer switch (gpa.deinit()) {
        .leak => std.debug.panic("Some memory leaked!", .{}),
        .ok => {},
    };

    const handle = stdin.handle;
    try enableRawMode(handle);
    try state.reset(&stdout, arena.allocator());
    if (std.os.argv.len > 1) {
        try editorOpen(std.mem.span(std.os.argv[1]));
    }

    try editorSetStatusMessage("Ctrl+S: save, Ctrl+Q: quit.");

    defer disableRawMode(handle, &stdout) catch |err| {
        std.debug.print("Failed to restore the original terminal mode: {}", .{err});
    };

    while (true) {
        try editorRefreshScreen(&stdout, &allocator);
        if (!try editorProcessKeypress(&reader)) {
            break;
        }
    }
}
