const std = @import("std");
const main = @import("main.zig");
const str = @import("string.zig");
const row = @import("row.zig");
const config = @import("config.zig");
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

inline fn ctrlKey(k: u8) u8 {
    return k & 0x1f;
}

pub const Mode = enum {
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

pub const Editor = struct {
    allocator: std.mem.Allocator,
    stdin: std.fs.File,
    stdout: std.fs.File,
    handle: std.posix.fd_t,
    reader: std.fs.File.Reader,
    stdin_buffer: [1024]u8,
    state: *main.Buffer,
    mode: Mode,
    orig_term: posix.system.termios,

    pub fn init(allocator: std.mem.Allocator) !*Editor {
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
        self.state = &main.state;
        self.mode = Mode.normal;

        try self.enableRawMode(self.handle);
        try self.state.reset(&self.stdout, &self.reader, self.allocator);
        return self;
    }

    fn enableRawMode(self: *Editor, handle: posix.fd_t) !void {
        self.orig_term = try posix.tcgetattr(handle);
        var term = self.orig_term;
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

    pub fn disableRawMode(self: *Editor, handle: posix.fd_t, writer: *const std.fs.File) !void {
        // Clear screen and move cursort to the top left.
        try writer.writeAll("\x1b[H\x1b[2J");
        try posix.tcsetattr(handle, .NOW, self.orig_term);
    }

    pub fn deinit(self: *Editor) void {
        self.disableRawMode(self.handle, &self.stdout) catch |err| {
            std.debug.print("Failed to restore the original terminal mode: {}", .{err});
        };
        self.state.deinit();
        self.allocator.destroy(self);
    }

    pub fn open(self: *Editor, fname: []const u8) !void {
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
        self.state.filename = try self.allocator.dupe(u8, fname);
        editorSetCommentChars();

        // InsertRow calls above modify the dirty counter -> reset.
        self.state.dirty = 0;
    }

    pub fn processKeypress(self: *Editor, c: u16) !bool {
        return switch (self.mode) {
            Mode.normal => try self.processKeypressNormal(c),
            Mode.insert => try self.processKeypressInsert(c),
        };
    }

    fn processKeypressNormal(self: *Editor, c: u16) !bool {
        // To be replace by current buffer.
        const state = self.state;
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
                    defer self.allocator.free(cmd);
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
        // To be replace by current buffer.
        const state = self.state;
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

    fn drawStatusBar(self: *Editor, str_buffer: *str.String) !void {
        try str_buffer.append("\x1b[7m");

        // Reserve space for lines.
        var lbuffer: [100]u8 = undefined;
        const lines = try std.fmt.bufPrint(&lbuffer, " {s} {d}/{d}", .{ @tagName(self.mode), main.state.cy + 1, main.state.rows.items.len });

        const mod_string = if (main.state.dirty > 0) " (modified)" else "";
        const emptyspots = main.state.screencols - lines.len - mod_string.len;

        // Should we truncate from the left? What does vim do?
        var fname = main.state.filename orelse "[no name]";
        if (fname.len > emptyspots) {
            fname = fname[0..emptyspots];
        }
        try str_buffer.append(fname);
        try str_buffer.append(mod_string);

        const nspaces = emptyspots - fname.len;
        if (nspaces > 0) {
            const spaces_mem = try self.allocator.alloc(u8, nspaces);
            @memset(spaces_mem, ' ');
            try str_buffer.append(spaces_mem);
            self.allocator.free(spaces_mem);
        }

        try str_buffer.append(lines);
        try str_buffer.append("\x1b[m");
        try str_buffer.append("\r\n");
    }

    pub fn refreshScreen(self: *Editor) !void {
        editorScroll();
        // TODO: Make this bigger?
        var str_buf = try str.String.init(80, self.allocator);
        defer str_buf.deinit();

        try str_buf.append("\x1b[?25l");
        try str_buf.append("\x1b[H");
        try editorDrawRows(str_buf);
        try self.drawStatusBar(str_buf);
        try editorDrawMessageBar(str_buf);
        var buf: [20]u8 = undefined;
        const escape_code = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ main.state.cy - main.state.rowoffset + 1, main.state.rx - main.state.coloffset + 1 });
        try str_buf.append(escape_code);

        try str_buf.append("\x1b[?25h");
        try main.state.stdout.writeAll(str_buf.content());
    }

    fn editorPrompt(self: *Editor, prompt: []const u8) !?[]u8 {
        var command_buf = try self.allocator.alloc(u8, 80);
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
                    const new_buffer = try self.allocator.alloc(u8, command_buf_len - promptlen);
                    @memcpy(new_buffer, command_buf[promptlen..command_buf_len]);
                    self.allocator.free(command_buf);
                    return new_buffer;
                }
            } else if (c > 0 and c < 128) {
                const casted_char = std.math.cast(u8, c) orelse return error.ValueTooBig;
                if (!std.ascii.isControl(casted_char)) {
                    const curlen = command_buf.len;
                    if (command_buf_len == curlen - 1) {
                        const new_command_buf = try self.allocator.alloc(u8, 2 * curlen);
                        std.mem.copyForwards(u8, new_command_buf[0..curlen], command_buf[0..curlen]);
                        defer self.allocator.free(command_buf);
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
                defer self.allocator.free(fname);
                main.state.filename = try self.allocator.dupe(u8, fname);
            }
        }
        if (main.state.filename) |fname| {
            editorSetCommentChars();
            const buf = try main.state.rowsToString();
            defer self.allocator.free(buf);
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
            main.state.dirty = 0;
        } else {
            try editorSetStatusMessage("Save aborted.");
            return;
        }
    }
};

pub fn editorReadKey() !u16 {
    var oldreader = main.state.reader.interface.adaptToOldInterface();
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
    if (main.state.dirty > 0 and main.state.confirm_to_quit) {
        main.state.confirm_to_quit = false;
        try editorSetStatusMessage("You have unsaved changes. Use the quit command again if you still want to quit.");
        return true;
    }
    return false;
}

fn editorCommentLine() !void {
    var to_comment = true;
    if (main.state.rows.items[main.state.cy].content.len >= main.state.comment_chars.len) {
        to_comment = !std.mem.startsWith(u8, main.state.rows.items[main.state.cy].content, main.state.comment_chars);
    }
    for (main.state.comment_chars, 0..) |cs, i| {
        if (to_comment) {
            try main.state.rows.items[main.state.cy].insertChar(cs, i);
            main.state.cx += 1;
        } else {
            main.state.rows.items[main.state.cy].delChar(0);
            if (main.state.cx > 0) {
                main.state.cx -= 1;
            }
        }
    }
    try main.state.rows.items[main.state.cy].update();
    main.state.dirty += 1;
}

fn editorScroll() void {
    main.state.rx = 0;
    if (main.state.cy < main.state.rows.items.len) {
        main.state.rx = main.state.rows.items[main.state.cy].cxToRx(main.state.cx);
    }

    if (main.state.cy < main.state.rowoffset) {
        main.state.rowoffset = main.state.cy;
    }
    if (main.state.cy >= main.state.rowoffset + main.state.screenrows) {
        main.state.rowoffset = main.state.cy - main.state.screenrows + 1;
    }
    if (main.state.rx < main.state.coloffset) {
        main.state.coloffset = main.state.rx;
    }
    if (main.state.rx >= main.state.coloffset + main.state.screencols) {
        main.state.coloffset = main.state.rx - main.state.screencols + 1;
    }
}
fn editorDrawRows(str_buffer: *str.String) !void {
    for (0..main.state.screenrows) |crow| {
        const filerow = main.state.rowoffset + crow;
        // Erase in line, by default, erases everything to the right of cursor.
        if (filerow >= main.state.rows.items.len) {
            if (main.state.rows.items.len == 0 and crow == main.state.screenrows / 3) {
                if (main.state.screencols - welcome_msg.len >= 0) {
                    const padding = (main.state.screencols - welcome_msg.len) / 2;
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
            const offset_row = main.state.rows.items[filerow].render;
            if (offset_row.len >= main.state.coloffset) {
                var maxlen = offset_row.len - main.state.coloffset;
                if (maxlen > main.state.screencols) {
                    maxlen = main.state.screencols;
                }
                try str_buffer.append(offset_row[main.state.coloffset .. main.state.coloffset + maxlen]);
            }
        }
        try str_buffer.append("\x1b[K");
        try str_buffer.append("\r\n");
    }
}

fn editorDrawMessageBar(str_buffer: *str.String) !void {
    try str_buffer.append("\x1b[K");
    var msg = main.state.statusmsg;
    if (main.state.statusmsg.len > main.state.screencols) {
        msg = main.state.statusmsg[0..main.state.screencols];
    }
    if (main.state.statusmsg.len > 0 and std.time.timestamp() - main.state.statusmsg_time < config.STATUS_MSG_DURATION_SEC) {
        try str_buffer.append(main.state.statusmsg);
    }
}

fn editorMoveCursor(key: u16) void {
    switch (key) {
        KEY_LEFT => {
            if (main.state.cx > 0) {
                main.state.cx -= 1;
            }
        },
        KEY_DOWN => {
            if (main.state.cy < main.state.rows.items.len) {
                main.state.cy += 1;
            }
        },
        KEY_UP => {
            if (main.state.cy > 0) {
                main.state.cy -= 1;
            }
        },
        KEY_RIGHT => {
            if (main.state.cy < main.state.rows.items.len) {
                if (main.state.cx < main.state.rows.items[main.state.cy].content.len) {
                    main.state.cx += 1;
                }
            }
        },
        else => return,
    }
    const rowlen = if (main.state.cy < main.state.rows.items.len) main.state.rows.items[main.state.cy].content.len else 0;
    if (main.state.cx > rowlen) {
        main.state.cx = rowlen;
    }
}

fn editorSetCommentChars() void {
    const fname = main.state.filename orelse return;
    if (std.mem.endsWith(u8, fname, ".py")) {
        main.state.comment_chars = "#";
    }
}

fn editorInsertRow(at: usize, line: []u8) !void {
    if (at > main.state.rows.items.len) {
        return;
    }
    try main.state.rows.insert(at, try row.Row.init(line, main.state.allocator));

    try main.state.rows.items[at].update();
    main.state.dirty += 1;
}

fn editorInsertChar(c: u8) !void {
    if (main.state.cy == main.state.rows.items.len) {
        try editorInsertRow(main.state.cy, "");
    }
    try main.state.rows.items[main.state.cy].insertChar(c, main.state.cx);
    main.state.cx += 1;
}

fn editorSetStatusMessage(msg: []const u8) !void {
    // There is some formatting magic in the tutorial version of this.
    // Would probably be nicer not to format string before every message, but it also
    // simpler to some extent.
    main.state.allocator.free(main.state.statusmsg);
    main.state.statusmsg = try main.state.allocator.dupe(u8, msg);
    main.state.statusmsg_time = std.time.timestamp();
}

fn editorDelCharToLeft() !void {
    if (main.state.cy == main.state.rows.items.len) {
        return;
    }
    if (main.state.cx == 0 and main.state.cy == 0) {
        return;
    }
    // How can it be smaller than zero?
    var crow = main.state.rows.items[main.state.cy];
    if (main.state.cx > 0) {
        crow.delChar(main.state.cx - 1);
        main.state.cx -= 1;
    } else {
        // Move cursor to the joint of two new rows.
        var prev_row = main.state.rows.items[main.state.cy - 1];
        main.state.cx = prev_row.content.len;
        // Join the two rows.
        try prev_row.append(main.state.rows.items[main.state.cy].content);
        editorDelRow(main.state.cy); // Remove the current row
        main.state.cy -= 1; // Move cursor up.
    }
    try crow.update();
    main.state.dirty += 1;
}

fn editorDelRow(at: usize) void {
    if (at >= main.state.rows.items.len) {
        return;
    }
    const crow = main.state.rows.orderedRemove(at);
    crow.deinit();
    main.state.dirty += 1;
}

fn editorInsertNewLine() !void {
    if (main.state.cx == 0) {
        try editorInsertRow(main.state.cy, "");
    } else {
        var crow = main.state.rows.items[main.state.cy];
        try editorInsertRow(main.state.cy + 1, crow.content[main.state.cx..]);
        crow.content = crow.content[0..main.state.cx];
        try crow.update();
    }
    main.state.cy += 1;
    main.state.cx = 0;
    main.state.dirty += 1;
}
