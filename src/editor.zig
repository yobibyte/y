const std = @import("std");
const main = @import("main.zig");
const str = @import("string.zig");
const row = @import("row.zig");
const buffer = @import("buffer.zig");
const config = @import("config.zig");
const term = @import("term.zig");
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
    cur_buffer: *buffer.Buffer,
    mode: Mode,
    orig_term: posix.system.termios,
    screenrows: usize,
    screencols: usize,
    statusmsg: []const u8,
    statusmsg_time: i64,

    pub fn init(allocator: std.mem.Allocator) !*Editor {
        var self = try allocator.create(Editor);
        self.allocator = allocator;

        self.stdin = std.fs.File.stdin();
        self.stdout = std.fs.File.stdout();
        self.stdin_buffer = undefined;
        self.reader = self.stdin.reader(&self.stdin_buffer);
        self.handle = self.stdin.handle;

        const ws = try term.getWindowSize(&self.stdout);
        self.screenrows = ws[0] - 2;
        self.screencols = ws[1];

        // This is temporal. I will split the state into two parts:
        // Some of the editor-level vars will move to just Editor fields.
        // The rest, like Rows, will become buffers, and editor will keep a list (or a map) of buffers.
        self.cur_buffer = undefined;
        self.mode = Mode.normal;
        self.statusmsg = "";
        self.statusmsg_time = 0;

        try self.enableRawMode(self.handle);
        self.cur_buffer = try buffer.Buffer.init(self.allocator, self.screenrows, self.screencols);
        return self;
    }

    fn enableRawMode(self: *Editor, handle: posix.fd_t) !void {
        self.orig_term = try posix.tcgetattr(handle);
        var cterm = self.orig_term;
        cterm.lflag.ECHO = !cterm.lflag.ECHO;
        cterm.lflag.ISIG = !cterm.lflag.ISIG;
        cterm.lflag.ICANON = !cterm.lflag.ICANON;
        cterm.lflag.IEXTEN = !cterm.lflag.IEXTEN;
        cterm.iflag.IXON = !cterm.iflag.IXON;
        cterm.iflag.ICRNL = !cterm.iflag.ICRNL;
        cterm.iflag.BRKINT = !cterm.iflag.BRKINT;
        cterm.iflag.INPCK = !cterm.iflag.INPCK;
        cterm.iflag.ISTRIP = !cterm.iflag.ISTRIP;
        cterm.oflag.OPOST = !cterm.oflag.OPOST;
        cterm.cflag.CSIZE = posix.CSIZE.CS8;
        cterm.cc[@intFromEnum(posix.V.MIN)] = 0;
        cterm.cc[@intFromEnum(posix.V.TIME)] = 1;
        try posix.tcsetattr(handle, .NOW, cterm);
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
        self.cur_buffer.deinit();
        self.allocator.free(self.statusmsg);
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
            try self.insertRow(self.cur_buffer.rows.items.len, line);
        }
        self.cur_buffer.filename = try self.allocator.dupe(u8, fname);
        self.setCommentChars();

        // InsertRow calls above modify the dirty counter -> reset.
        self.cur_buffer.dirty = 0;
    }

    pub fn processKeypress(self: *Editor, c: u16) !bool {
        return switch (self.mode) {
            Mode.normal => try self.processKeypressNormal(c),
            Mode.insert => try self.processKeypressInsert(c),
        };
    }

    fn processKeypressNormal(self: *Editor, c: u16) !bool {
        // To be replace by current buffer.
        const state = self.cur_buffer;
        switch (c) {
            0 => return true, // 0 is EndOfStream.
            'h' => self.moveCursor(KEY_LEFT),
            'j' => self.moveCursor(KEY_DOWN),
            'k' => self.moveCursor(KEY_UP),
            'l' => self.moveCursor(KEY_RIGHT),
            'i' => self.mode = Mode.insert,
            's' => try self.save(),
            'q' => return self.quit(),
            'x', KEY_DEL => {
                if (state.cy < state.rows.items.len) {
                    if (state.cx < state.rows.items[state.cy].content.len) {
                        self.moveCursor(KEY_RIGHT);
                    }
                    try self.delCharToLeft();
                }
            },
            'G' => state.cy = state.rows.items.len - 1,
            // Example of using a command prompt.
            KEY_PROMPT => {
                const maybe_cmd = try self.get_prompt(":");
                if (maybe_cmd) |cmd| {
                    defer self.allocator.free(cmd);
                    if (std.mem.eql(u8, cmd, "c")) {
                        try self.commentLine();
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
        const state = self.cur_buffer;
        switch (c) {
            0 => return true, // 0 is EndOfStream.
            '\r' => try self.insertNewLine(),
            ctrlKey('q') => return self.quit(),
            KEY_UP, KEY_DOWN, KEY_RIGHT, KEY_LEFT => self.moveCursor(c),
            KEY_BACKSPACE, KEY_DEL, ctrlKey('h') => {
                if (c == KEY_DEL) {
                    // We should be joining the two rows in here in the insert mode.
                    if (state.cy < state.rows.items.len) {
                        if (state.cx == state.rows.items[state.cy].content.len) {
                            state.cx = 0;
                            self.moveCursor(KEY_DOWN);
                        } else {
                            self.moveCursor(KEY_RIGHT);
                        }
                        try self.delCharToLeft();
                    }
                } else {
                    try self.delCharToLeft();
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
                    self.moveCursor(if (c == KEY_PGUP) KEY_UP else KEY_DOWN);
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
                    try self.insertChar(casted_char);
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
        const lines = try std.fmt.bufPrint(&lbuffer, " {s} {d}/{d}", .{ @tagName(self.mode), self.cur_buffer.cy + 1, self.cur_buffer.rows.items.len });

        const mod_string = if (self.cur_buffer.dirty > 0) " (modified)" else "";
        const emptyspots = self.cur_buffer.screencols - lines.len - mod_string.len;

        // Should we truncate from the left? What does vim do?
        var fname = self.cur_buffer.filename orelse "[no name]";
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
        self.scroll();
        // TODO: Make this bigger?
        var str_buf = try str.String.init(80, self.allocator);
        defer str_buf.deinit();

        try str_buf.append("\x1b[?25l");
        try str_buf.append("\x1b[H");
        try self.drawRows(str_buf);
        try self.drawStatusBar(str_buf);
        try self.drawMessageBar(str_buf);
        var buf: [20]u8 = undefined;
        const escape_code = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ self.cur_buffer.cy - self.cur_buffer.rowoffset + 1, self.cur_buffer.rx - self.cur_buffer.coloffset + 1 });
        try str_buf.append(escape_code);

        try str_buf.append("\x1b[?25h");
        try self.stdout.writeAll(str_buf.content());
    }

    fn get_prompt(self: *Editor, prompt: []const u8) !?[]u8 {
        var command_buf = try self.allocator.alloc(u8, 80);
        var command_buf_len: usize = prompt.len;
        const promptlen = prompt.len;
        std.mem.copyForwards(u8, command_buf[0..promptlen], prompt);

        while (true) {
            try self.setStatusMessage(command_buf[0..command_buf_len]);
            try self.refreshScreen();

            const c: u16 = try self.readKey();

            if (c == KEY_DEL or c == ctrlKey('h') or c == KEY_BACKSPACE) {
                // we should be able to move around here and DEL should behave differently from BACKSPACE.
                if (command_buf_len != promptlen) {
                    command_buf_len -= 1;
                }
            } else if (c == '\x1b') {
                try self.setStatusMessage("");
                return null;
            } else if (c == '\r') {
                if (command_buf_len != 0) {
                    try self.setStatusMessage("");
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
        if (self.cur_buffer.filename == null) {
            const prompt = try self.get_prompt("Save as: ");
            if (prompt) |fname| {
                defer self.allocator.free(fname);
                self.cur_buffer.filename = try self.allocator.dupe(u8, fname);
            }
        }
        if (self.cur_buffer.filename) |fname| {
            self.setCommentChars();
            const buf = try self.cur_buffer.rowsToString();
            defer self.allocator.free(buf);
            const file = try std.fs.cwd().createFile(fname, .{ .truncate = true });
            defer file.close();

            file.writeAll(buf) catch |err| {
                var err_buf: [100]u8 = undefined;
                const failure_msg = try std.fmt.bufPrint(&err_buf, "Failed to save a file: {}", .{err});
                try self.setStatusMessage(failure_msg);
                return;
            };
            var fmt_buf: [100]u8 = undefined;
            const success_msg = try std.fmt.bufPrint(&fmt_buf, "{d} bytes written to disk.", .{buf.len});
            try self.setStatusMessage(success_msg);
            self.cur_buffer.dirty = 0;
        } else {
            try self.setStatusMessage("Save aborted.");
            return;
        }
    }

    pub fn readKey(self: *Editor) !u16 {
        var oldreader = self.reader.interface.adaptToOldInterface();
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

    fn quit(self: *Editor) !bool {
        if (self.cur_buffer.dirty > 0 and self.cur_buffer.confirm_to_quit) {
            self.cur_buffer.confirm_to_quit = false;
            try self.setStatusMessage("You have unsaved changes. Use the quit command again if you still want to quit.");
            return true;
        }
        return false;
    }

    fn commentLine(self: *Editor) !void {
        var to_comment = true;
        if (self.cur_buffer.rows.items[self.cur_buffer.cy].content.len >= self.cur_buffer.comment_chars.len) {
            to_comment = !std.mem.startsWith(u8, self.cur_buffer.rows.items[self.cur_buffer.cy].content, self.cur_buffer.comment_chars);
        }
        for (self.cur_buffer.comment_chars, 0..) |cs, i| {
            if (to_comment) {
                try self.cur_buffer.rows.items[self.cur_buffer.cy].insertChar(cs, i);
                self.cur_buffer.cx += 1;
            } else {
                try self.cur_buffer.rows.items[self.cur_buffer.cy].delChar(0);
                if (self.cur_buffer.cx > 0) {
                    self.cur_buffer.cx -= 1;
                }
            }
        }
        try self.cur_buffer.rows.items[self.cur_buffer.cy].update();
        self.cur_buffer.dirty += 1;
    }

    fn scroll(self: *Editor) void {
        self.cur_buffer.rx = 0;
        if (self.cur_buffer.cy < self.cur_buffer.rows.items.len) {
            self.cur_buffer.rx = self.cur_buffer.rows.items[self.cur_buffer.cy].cxToRx(self.cur_buffer.cx);
        }

        if (self.cur_buffer.cy < self.cur_buffer.rowoffset) {
            self.cur_buffer.rowoffset = self.cur_buffer.cy;
        }
        if (self.cur_buffer.cy >= self.cur_buffer.rowoffset + self.cur_buffer.screenrows) {
            self.cur_buffer.rowoffset = self.cur_buffer.cy - self.cur_buffer.screenrows + 1;
        }
        if (self.cur_buffer.rx < self.cur_buffer.coloffset) {
            self.cur_buffer.coloffset = self.cur_buffer.rx;
        }
        if (self.cur_buffer.rx >= self.cur_buffer.coloffset + self.cur_buffer.screencols) {
            self.cur_buffer.coloffset = self.cur_buffer.rx - self.cur_buffer.screencols + 1;
        }
    }
    fn drawRows(self: *Editor, str_buffer: *str.String) !void {
        for (0..self.cur_buffer.screenrows) |crow| {
            const filerow = self.cur_buffer.rowoffset + crow;
            // Erase in line, by default, erases everything to the right of cursor.
            if (filerow >= self.cur_buffer.rows.items.len) {
                if (self.cur_buffer.rows.items.len == 0 and crow == self.cur_buffer.screenrows / 3) {
                    if (self.cur_buffer.screencols - welcome_msg.len >= 0) {
                        const padding = (self.cur_buffer.screencols - welcome_msg.len) / 2;
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
                const offset_row = self.cur_buffer.rows.items[filerow].render;
                if (offset_row.len >= self.cur_buffer.coloffset) {
                    var maxlen = offset_row.len - self.cur_buffer.coloffset;
                    if (maxlen > self.cur_buffer.screencols) {
                        maxlen = self.cur_buffer.screencols;
                    }
                    try str_buffer.append(offset_row[self.cur_buffer.coloffset .. self.cur_buffer.coloffset + maxlen]);
                }
            }
            try str_buffer.append("\x1b[K");
            try str_buffer.append("\r\n");
        }
    }

    fn drawMessageBar(self: *Editor, str_buffer: *str.String) !void {
        try str_buffer.append("\x1b[K");
        var msg = self.statusmsg;
        if (self.statusmsg.len > self.screencols) {
            msg = self.statusmsg[0..self.cur_buffer.screencols];
        }
        if (self.statusmsg.len > 0 and std.time.timestamp() - self.statusmsg_time < config.STATUS_MSG_DURATION_SEC) {
            try str_buffer.append(self.statusmsg);
        }
    }

    fn moveCursor(self: *Editor, key: u16) void {
        switch (key) {
            KEY_LEFT => {
                if (self.cur_buffer.cx > 0) {
                    self.cur_buffer.cx -= 1;
                }
            },
            KEY_DOWN => {
                if (self.cur_buffer.cy < self.cur_buffer.rows.items.len) {
                    self.cur_buffer.cy += 1;
                }
            },
            KEY_UP => {
                if (self.cur_buffer.cy > 0) {
                    self.cur_buffer.cy -= 1;
                }
            },
            KEY_RIGHT => {
                if (self.cur_buffer.cy < self.cur_buffer.rows.items.len) {
                    if (self.cur_buffer.cx < self.cur_buffer.rows.items[self.cur_buffer.cy].content.len) {
                        self.cur_buffer.cx += 1;
                    }
                }
            },
            else => return,
        }
        const rowlen = if (self.cur_buffer.cy < self.cur_buffer.rows.items.len) self.cur_buffer.rows.items[self.cur_buffer.cy].content.len else 0;
        if (self.cur_buffer.cx > rowlen) {
            self.cur_buffer.cx = rowlen;
        }
    }

    fn setCommentChars(self: *Editor) void {
        const fname = self.cur_buffer.filename orelse return;
        if (std.mem.endsWith(u8, fname, ".py")) {
            self.cur_buffer.comment_chars = "#";
        }
    }

    fn insertRow(self: *Editor, at: usize, line: []u8) !void {
        if (at > self.cur_buffer.rows.items.len) {
            return;
        }
        try self.cur_buffer.rows.insert(at, try row.Row.init(line, self.cur_buffer.allocator));

        try self.cur_buffer.rows.items[at].update();
        self.cur_buffer.dirty += 1;
    }

    fn insertChar(self: *Editor, c: u8) !void {
        if (self.cur_buffer.cy == self.cur_buffer.rows.items.len) {
            try self.insertRow(self.cur_buffer.cy, "");
        }
        try self.cur_buffer.rows.items[self.cur_buffer.cy].insertChar(c, self.cur_buffer.cx);
        self.cur_buffer.cx += 1;
    }

    fn setStatusMessage(self: *Editor, msg: []const u8) !void {
        // There is some formatting magic in the tutorial version of this.
        // Would probably be nicer not to format string before every message, but it also
        // simpler to some extent.
        self.cur_buffer.allocator.free(self.statusmsg);
        self.statusmsg = try self.cur_buffer.allocator.dupe(u8, msg);
        self.statusmsg_time = std.time.timestamp();
    }

    fn delCharToLeft(self: *Editor) !void {
        if (self.cur_buffer.cy == self.cur_buffer.rows.items.len) {
            return;
        }
        if (self.cur_buffer.cx == 0 and self.cur_buffer.cy == 0) {
            return;
        }
        // How can it be smaller than zero?
        var crow = self.cur_buffer.rows.items[self.cur_buffer.cy];
        if (self.cur_buffer.cx > 0) {
            try crow.delChar(self.cur_buffer.cx - 1);
            self.cur_buffer.cx -= 1;
        } else {
            // Move cursor to the joint of two new rows.
            var prev_row = self.cur_buffer.rows.items[self.cur_buffer.cy - 1];
            self.cur_buffer.cx = prev_row.content.len;
            // Join the two rows.
            try prev_row.append(self.cur_buffer.rows.items[self.cur_buffer.cy].content);
            self.delRow(self.cur_buffer.cy); // Remove the current row
            self.cur_buffer.cy -= 1; // Move cursor up.
        }
        try crow.update();
        self.cur_buffer.dirty += 1;
    }

    fn delRow(self: *Editor, at: usize) void {
        if (at >= self.cur_buffer.rows.items.len) {
            return;
        }
        const crow = self.cur_buffer.rows.orderedRemove(at);
        crow.deinit();
        self.cur_buffer.dirty += 1;
    }

    fn insertNewLine(self: *Editor) !void {
        if (self.cur_buffer.cx == 0) {
            try self.insertRow(self.cur_buffer.cy, "");
        } else {
            var crow = self.cur_buffer.rows.items[self.cur_buffer.cy];
            try self.insertRow(self.cur_buffer.cy + 1, crow.content[self.cur_buffer.cx..]);
            crow.content = crow.content[0..self.cur_buffer.cx];
            try crow.update();
        }
        self.cur_buffer.cy += 1;
        self.cur_buffer.cx = 0;
        self.cur_buffer.dirty += 1;
    }
};
