const std = @import("std");
const row = @import("row.zig");
const str = @import("lib/ylib/string.zig");
const buffer = @import("buffer.zig");
const config = @import("config.zig");
const term = @import("lib/ylib/term.zig");
const posix = std.posix;
const kb = @import("kb.zig");
const common = @import("common.zig");

inline fn ctrlKey(k: u8) u8 {
    return k & 0x1f;
}

pub const CommandBuffer = struct {
    allocator: std.mem.Allocator,
    // TODO: can I make everything on the stack here?
    data: []u8,
    len: usize,

    fn init(allocator: std.mem.Allocator) !*CommandBuffer {
        var self = try allocator.create(CommandBuffer);
        self.data = try allocator.alloc(u8, 20);
        self.len = 0;
        self.allocator = allocator;
        return self;
    }

    fn deinit(self: *CommandBuffer) void {
        self.allocator.free(self.data);
        self.allocator.destroy(self);
    }

    fn clear(self: *CommandBuffer) void {
        self.len = 0;
    }

    fn cmd(self: *CommandBuffer) []u8 {
        return self.data[0..self.len];
    }

    fn append(self: *CommandBuffer, c: u8) void {
        self.data[self.len] = c;
        self.len += 1;
        if (self.len >= 20) {
            self.len = 0;
        }
    }
};

pub const Editor = struct {
    allocator: std.mem.Allocator,
    stdin: std.fs.File,
    stdout: std.fs.File,
    handle: std.posix.fd_t,
    reader: std.fs.File.Reader,
    stdin_buffer: [1024]u8,
    buffers: std.array_list.Managed(*buffer.Buffer),
    cur_buffer_idx: usize,
    mode: common.Mode,
    orig_term: posix.system.termios,
    screenrows: usize,
    screencols: usize,
    statusmsg: []const u8,
    statusmsg_time: i64,
    search_pattern: ?[]const u8,
    cmd_buffer: *CommandBuffer,
    quit_flag: bool,
    register: []u8,

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
        self.mode = common.Mode.normal;
        self.statusmsg = "";
        self.statusmsg_time = 0;
        self.register = "";

        self.search_pattern = null;

        self.cur_buffer_idx = undefined;
        self.orig_term = try term.enableRawMode(self.handle);

        self.buffers = std.array_list.Managed(*buffer.Buffer).init(allocator);
        self.cmd_buffer = try CommandBuffer.init(self.allocator);
        self.quit_flag = false;
        return self;
    }

    pub fn deinit(self: *Editor) void {
        term.disableRawMode(self.orig_term, self.handle, &self.stdout) catch |err| {
            std.debug.print("Failed to restore the original terminal mode: {}", .{err});
        };
        self.allocator.free(self.statusmsg);
        if (self.search_pattern) |sp| {
            self.allocator.free(sp);
        }
        self.cmd_buffer.deinit();
        for (self.buffers.items) |buf| {
            buf.deinit();
        }
        self.allocator.free(self.register);
        self.buffers.deinit();
        self.allocator.destroy(self);
    }

    pub fn add_buffer(self: *Editor, maybe_fname: ?[]const u8) !void {
        const newbuf = try buffer.Buffer.init(self.allocator, self.screenrows, self.screencols, maybe_fname);
        try self.buffers.insert(self.buffers.items.len, newbuf);
        self.cur_buffer_idx = self.buffers.items.len - 1;
    }
    fn next_buffer(self: *Editor) void {
        self.cur_buffer_idx += 1;
        if (self.cur_buffer_idx > self.buffers.items.len - 1) {
            self.cur_buffer_idx = 0;
        }
    }
    fn prev_buffer(self: *Editor) void {
        if (self.cur_buffer_idx == 0) {
            self.cur_buffer_idx = self.buffers.items.len - 1;
        } else {
            self.cur_buffer_idx -= 1;
        }
    }
    pub fn cur_buffer(self: *Editor) *buffer.Buffer {
        return self.buffers.items[self.cur_buffer_idx];
    }

    pub fn processKeypress(self: *Editor, c: u16) !void {
        switch (self.mode) {
            common.Mode.normal => try self.processKeypressNormal(c),
            common.Mode.insert => try self.processKeypressInsert(c),
            common.Mode.visual => try self.processKeypressVisual(c),
        }
    }

    fn moveCursor(self: *Editor, key: u16) void {
        self.cur_buffer().moveCursor(key, self.mode);
        if (self.cur_buffer().sel_start.cmp(&self.cur_buffer().sel_end) == .gt) {
            self.cur_buffer().reset_sel();
            self.mode = common.Mode.normal;
        }
    }

    fn pasteAfter(self: *Editor) !void {
        var it = std.mem.splitScalar(u8, self.register, '\n');
        const cbuf = self.cur_buffer();
        while (it.next()) |line| {
            // TODO: to paste not only full lines, instead of append, we should add at an index.
            // TODO: we should also keep track of the cx index and do row.update()
            try cbuf.rows.items[cbuf.cy].append(line);
            if (it.peek()) |_| {
                try cbuf.insertRow(cbuf.cy + 1, "");
                cbuf.cy += 1;
            }
        }
    }

    fn processKeypressNormal(self: *Editor, c: u16) !void {
        // To be replace by current buffer.
        const state = self.cur_buffer();
        if (c == ctrlKey('l') or c == '\x1b') {
            self.cmd_buffer.clear();
            return;
        }
        if (self.cmd_buffer.len > 0 and c != 0) {
            try self.processExtendedCommand(c);
            return;
        }
        switch (c) {
            0,
            => return, // 0 is EndOfStream.
            // TODO: read about ctrl+l, is this an Esc?
            // It was in the tutorial, but I forgot.
            ctrlKey('l'), '\x1b' => {
                return;
            },
            ']' => self.next_buffer(),
            '[' => self.prev_buffer(),
            '0' => self.moveCursor(kb.KEY_HOME),
            '$' => self.moveCursor(kb.KEY_END),
            'h' => self.moveCursor(kb.KEY_LEFT),
            'j' => self.moveCursor(kb.KEY_DOWN),
            'c' => try self.cur_buffer().commentLine(),
            'k' => self.moveCursor(kb.KEY_UP),
            'l' => self.moveCursor(kb.KEY_RIGHT),
            'p' => try self.pasteAfter(),
            'v' => {
                self.mode = common.Mode.visual;
                self.cur_buffer().sel_start.x = self.cur_buffer().rx;
                self.cur_buffer().sel_start.y = self.cur_buffer().cy;
                self.cur_buffer().sel_end.x = self.cur_buffer().rx + 1;
                // Select 1 char.
                self.cur_buffer().sel_end.y = self.cur_buffer().cy;
            },
            'i' => self.mode = common.Mode.insert,
            'a' => {
                self.mode = common.Mode.insert;
                self.moveCursor(kb.KEY_RIGHT);
            },
            'o' => {
                self.mode = common.Mode.insert;
                self.moveCursor(kb.KEY_END);
                try self.cur_buffer().insertNewLine();
            },
            'w' => self.cur_buffer().goToNextWord(),
            's' => try self.save(),
            '/' => try self.search(true),
            'n' => try self.search(false),
            'q' => try self.quit(false),
            'Q' => try self.quit(true),
            'x', kb.KEY_DEL => {
                if (state.cy < state.len()) {
                    if (state.cx < state.rows.items[state.cy].content.len) {
                        self.moveCursor(kb.KEY_RIGHT);
                    }
                    try self.cur_buffer().delCharToLeft();
                }
            },
            'G' => {
                state.cy = state.len() - 1;
                state.cx = 0;
            },
            // Example of using a command prompt.
            kb.KEY_PROMPT => {
                const maybe_cmd = try self.get_prompt(":");
                if (maybe_cmd) |cmd| {
                    defer self.allocator.free(cmd);
                    if (std.mem.eql(u8, cmd, "c")) {
                        try self.cur_buffer().commentLine();
                        // check for length here!
                    } else if (std.mem.eql(u8, cmd[0..2], "e ")) {
                        try self.add_buffer(cmd[2..]);
                    } else if (std.mem.eql(u8, cmd, "bd")) {
                        return try self.close_buffer(false);
                    } else if (std.mem.eql(u8, cmd, "bd!")) {
                        return try self.close_buffer(true);
                    } else if (std.mem.eql(u8, cmd, "bn")) {
                        self.next_buffer();
                    } else if (std.mem.eql(u8, cmd, "bp")) {
                        self.prev_buffer();
                    } else {
                        const number = std.fmt.parseInt(usize, cmd, 10) catch 0;
                        if (number > 0 and number <= state.len()) {
                            state.cy = number - 1;
                        }
                    }
                }
            },
            else => try self.processExtendedCommand(c),
        }
    }

    fn processExtendedCommand(self: *Editor, c: u16) !void {
        // TODO: Is this a correct check?
        if (c < 128) {
            const casted_char = std.math.cast(u8, c) orelse return error.ValueTooBig;
            self.cmd_buffer.append(casted_char);
        }
        if (self.cmd_buffer.len == 0) {
            return;
        }

        // This has to be rewritten with regexes when I implement the regex engine.
        const cmd = self.cmd_buffer.cmd();
        if (std.mem.eql(u8, cmd, "gg")) {
            self.cur_buffer().cx = 0;
            self.cur_buffer().cy = 0;
        } else if (std.mem.eql(u8, cmd, "yy")) {
            const content = self.cur_buffer().rows.items[self.cur_buffer().cy].content;
            self.register = try self.allocator.alloc(u8, content.len);
            std.mem.copyForwards(u8, self.register[0..content.len], content);
        } else if (std.mem.eql(u8, cmd, "dd")) {
            const maybe_row = self.cur_buffer().delRow(null);
            if (maybe_row) |crow| {
                // TODO: factor out to a method: update register.
                self.allocator.free(self.register);
                self.register = try self.allocator.alloc(u8, crow.content.len + 1);
                self.register[0] = '\n';
                std.mem.copyForwards(u8, self.register[1 .. crow.content.len + 1], crow.content);
                crow.deinit();
            }
        } else {
            var last_number_idx: usize = cmd.len;
            for (0..cmd.len) |i| {
                if (cmd[i] < '0' or cmd[i] > '9') {
                    break;
                }
                last_number_idx = i;
            }
            // If all chars are digits, we skip.
            if (last_number_idx < cmd.len - 1) {
                const number: usize = try std.fmt.parseInt(usize, cmd[0 .. last_number_idx + 1], 10);
                const unmod_cmd = cmd[last_number_idx + 1 ..];
                if (cmd.len > 2 and last_number_idx == cmd.len - 3 and std.mem.eql(u8, unmod_cmd, "gg")) {
                    // This check should be done on row side
                    if (number <= self.cur_buffer().len()) {
                        self.cur_buffer().cy = number - 1;
                    }
                } else if (last_number_idx == cmd.len - 2) {
                    for (0..number) |_| {
                        // Only one char left.
                        switch (unmod_cmd[0]) {
                            'h' => self.moveCursor(kb.KEY_LEFT),
                            'j' => self.moveCursor(kb.KEY_DOWN),
                            'k' => self.moveCursor(kb.KEY_UP),
                            'l' => self.moveCursor(kb.KEY_RIGHT),
                            else => return,
                        }
                    }
                }
            } else {
                return;
            }
        }

        self.cmd_buffer.clear();
    }

    fn processKeypressInsert(self: *Editor, c: u16) !void {
        // To be replace by current buffer.
        const state = self.cur_buffer();
        switch (c) {
            0 => return, // 0 is EndOfStream.
            '\r' => try self.cur_buffer().insertNewLine(),
            '\t' => {
                // Expand tabs.
                for (0..config.TAB_WIDTH) |_| {
                    try self.cur_buffer().insertChar(' ');
                }
            },
            kb.KEY_UP, kb.KEY_DOWN, kb.KEY_RIGHT, kb.KEY_LEFT => self.moveCursor(c),
            kb.KEY_BACKSPACE, kb.KEY_DEL, ctrlKey('h') => {
                if (c == kb.KEY_DEL) {
                    // We should be joining the two rows in here in the insert mode.
                    if (state.cy < state.len()) {
                        if (state.cx == state.rows.items[state.cy].content.len) {
                            state.cx = 0;
                            self.moveCursor(kb.KEY_DOWN);
                        } else {
                            self.moveCursor(kb.KEY_RIGHT);
                        }
                        try self.cur_buffer().delCharToLeft();
                    }
                } else {
                    try self.cur_buffer().delCharToLeft();
                }
            },
            kb.KEY_PGUP, kb.KEY_PGDOWN => {
                if (c == kb.KEY_PGUP) {
                    state.cy = state.rowoffset;
                } else {
                    state.cy = state.rowoffset + state.screenrows - 1;
                    if (state.cy > state.len()) {
                        state.cy = state.len();
                    }
                }
                for (0..state.screenrows) |_| {
                    self.moveCursor(if (c == kb.KEY_PGUP) kb.KEY_UP else kb.KEY_DOWN);
                }
            },
            ctrlKey('s') => try self.save(),
            kb.KEY_HOME => {
                state.cx = 0;
            },
            kb.KEY_END => {
                if (state.cy < state.len()) {
                    state.cx = state.rows.items[state.cy].content.len - 1;
                }
            },

            ctrlKey('l'), '\x1b' => {
                self.mode = common.Mode.normal;
            },
            else => {
                const casted_char = std.math.cast(u8, c) orelse return error.ValueTooBig;
                if (!std.ascii.isControl(casted_char)) {
                    try self.cur_buffer().insertChar(casted_char);
                }
            },
        }
    }

    fn processKeypressVisual(self: *Editor, c: u16) !void {
        switch (c) {
            0 => {}, // 0 is EndOfStream.
            // TODO: read about ctrl+l, is this an Esc?
            // It was in the tutorial, but I forgot.
            ctrlKey('l'), '\x1b' => {
                self.mode = common.Mode.normal;
                self.cur_buffer().reset_sel();
            },
            '0' => self.moveCursor(kb.KEY_HOME),
            '$' => self.moveCursor(kb.KEY_END),
            'h' => self.moveCursor(kb.KEY_LEFT),
            'j' => self.moveCursor(kb.KEY_DOWN),
            'k' => self.moveCursor(kb.KEY_UP),
            'l' => self.moveCursor(kb.KEY_RIGHT),
            'x', kb.KEY_DEL => {
                var cbuf = self.cur_buffer();
                //TODO: I think most of this code should be moved to buffer.zig.
                const ss = cbuf.sel_start;
                const se = cbuf.sel_end;
                // TODO: this should be var, because we will iterate over row_idx.
                // until se.y if we do not remove rows
                var to_clipboard = try str.String.init(80, self.allocator);
                defer to_clipboard.deinit();
                // TODO fix the removing properly

                if (ss.y == se.y) {
                    // We are within one line only.
                    if (ss.x == se.x) {
                        // Removing all chars on a line = removing a whole row.
                        const maybe_row = self.cur_buffer().delRow(null);
                        if (maybe_row) |crow| {
                            try to_clipboard.append(crow.content);
                            try to_clipboard.append("\n");
                            crow.deinit();
                            cbuf.dirty += 1;
                        }
                        //TODO: remove dirty+=1 from every line? Make a single one per function?
                    } else {
                        try to_clipboard.append(cbuf.rows.items[ss.y].content[ss.x..se.x]);
                        for (ss.x..se.x) |_| {
                            // Everything contracts to the left, that's why we remove at the same pos.
                            try cbuf.rows.items[ss.y].delChar(ss.x);
                            cbuf.dirty += 1;
                        }
                    }
                    try cbuf.rows.items[ss.y].update();
                } else {
                    // multi-row delete logic
                    for (ss.y..se.y) |row_idx| {
                        const pre_change_row_len = cbuf.rows.items[row_idx].content.len;
                        std.debug.print("rlen {} ssx {}, ss.y {}, row_idx {}.", .{ pre_change_row_len, ss.x, ss.y, row_idx });
                        if (ss.y == row_idx) {
                            // First row of the selection.
                            // Remove post x.
                            // if starting at the beginning of the line,
                            // remove the whole row
                            if (ss.x == 0) {
                                try cbuf.rows.items[ss.y].delChar(ss.x);
                                cbuf.dirty += 1;
                                const maybe_row = self.cur_buffer().delRow(null);
                                if (maybe_row) |crow| {
                                    try to_clipboard.append(crow.content);
                                    crow.deinit();
                                }
                            } else {
                                // TODO: make a function in buffer or row?
                                //std.debug.assert(false);
                                for (ss.x..pre_change_row_len) |_| {
                                    self.moveCursor(kb.KEY_RIGHT);
                                    //BOOKMARK: start here, replace delChar with delCharToLeft, set buf cx before
                                    try cbuf.delCharToLeft();
                                }
                            }
                            try cbuf.rows.items[row_idx].update();
                        } else if (se.y == row_idx) {
                            // Last row of the selection.
                            // Remove pre x.
                            // if se.y is the last symbol, remove the whole row
                            if (se.x == pre_change_row_len) {
                                const maybe_row = self.cur_buffer().delRow(null);
                                if (maybe_row) |crow| {
                                    try to_clipboard.append(crow.content);
                                    crow.deinit();
                                }
                            } else {
                                for (0..se.x) |_| {
                                    // Everything contracts to the left, that's why we remove at the same pos.
                                    try cbuf.rows.items[row_idx].delChar(0);
                                }
                            }
                            try cbuf.rows.items[row_idx].update();
                        } else {
                            const maybe_row = self.cur_buffer().delRow(null);
                            if (maybe_row) |crow| {
                                try to_clipboard.append(crow.content);
                                crow.deinit();
                            }
                        }
                    }
                }
                // After all the modifications, the cursor should go to sel_start pos.
                cbuf.cx = ss.x;
                cbuf.cy = ss.y;
                self.allocator.free(self.register);
                self.register = try self.allocator.alloc(u8, to_clipboard.content().len);
                std.mem.copyForwards(u8, self.register[0..self.register.len], to_clipboard.content());
                self.mode = common.Mode.normal;
            },
            else => {},
        }
    }

    fn drawMessageBar(self: *Editor, str_buffer: *str.String) !void {
        try str_buffer.append("\x1b[K");
        var msg = self.statusmsg;
        if (self.statusmsg.len > self.screencols) {
            msg = self.statusmsg[0..self.screencols];
        }
        if (self.statusmsg.len > 0 and std.time.timestamp() - self.statusmsg_time < config.STATUS_MSG_DURATION_SEC) {
            try str_buffer.append(self.statusmsg);
        }
    }

    fn drawStatusBar(self: *Editor, str_buffer: *str.String) !void {
        try str_buffer.append("\x1b[7m");

        // Reserve space for lines.
        // TODO This has to be within screencols.
        var lbuffer: [100]u8 = undefined;
        const cmd_string = if (self.cmd_buffer.len > 0) self.cmd_buffer.cmd() else "";
        const lines = try std.fmt.bufPrint(&lbuffer, "{s} {s} {d}/{d}", .{ cmd_string, @tagName(self.mode), self.cur_buffer().cy + 1, self.cur_buffer().len() });

        const mod_string = if (self.cur_buffer().dirty > 0) " (modified)" else "";

        const emptyspots = self.cur_buffer().screencols - lines.len - mod_string.len;

        // Should we truncate from the left? What does vim do?
        var fname = self.cur_buffer().filename orelse "[no name]";
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
        self.cur_buffer().scroll();
        // TODO: Make this bigger?
        var str_buf = try str.String.init(80, self.allocator);
        defer str_buf.deinit();
        try str_buf.append("\x1b[?25l");
        try str_buf.append("\x1b[H");
        try self.cur_buffer().drawRows(str_buf, self.mode == common.Mode.visual);
        try self.drawStatusBar(str_buf);
        try self.drawMessageBar(str_buf);
        var buf: [20]u8 = undefined;
        const escape_code = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ self.cur_buffer().cy - self.cur_buffer().rowoffset + 1, self.cur_buffer().rx - self.cur_buffer().coloffset + 1 });
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

            if (c == kb.KEY_DEL or c == ctrlKey('h') or c == kb.KEY_BACKSPACE) {
                // we should be able to move around here and DEL should behave differently from BACKSPACE.
                if (command_buf_len != promptlen) {
                    command_buf_len -= 1;
                }
            } else if (c == '\x1b') {
                try self.setStatusMessage("");
                self.allocator.free(command_buf);
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
        if (self.cur_buffer().filename == null) {
            const prompt = try self.get_prompt("Save as: ");
            if (prompt) |fname| {
                defer self.allocator.free(fname);
                self.cur_buffer().filename = try self.allocator.dupe(u8, fname);
            }
        }
        if (self.cur_buffer().filename) |fname| {
            self.cur_buffer().setCommentChars();
            const buf = try self.cur_buffer().rowsToString();
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
            self.cur_buffer().dirty = 0;
        } else {
            try self.setStatusMessage("Save aborted.");
            return;
        }
    }

    pub fn readKey(self: *Editor) !u16 {
        const buf: []u8 = try self.allocator.alloc(u8, 100);
        defer self.allocator.free(buf);
        const bytes_read = self.reader.readStreaming(buf) catch |err| switch (err) {
            error.EndOfStream => return 0,
            else => return err,
        };
        if (buf[0] == '\x1b') {
            if (bytes_read == 1) {
                return '\x1b';
            }
            if (buf[1] == '[') {
                if (bytes_read == 2) {
                    return '\x1b';
                }
                switch (buf[2]) {
                    '1'...'9' => {
                        if (bytes_read == 3) {
                            return '\x1b';
                        }
                        if (buf[3] == '~') {
                            switch (buf[2]) {
                                '1' => return kb.KEY_HOME,
                                '3' => return kb.KEY_DEL,
                                '4' => return kb.KEY_END,
                                '5' => return kb.KEY_PGUP,
                                '6' => return kb.KEY_PGDOWN,
                                '7' => return kb.KEY_HOME,
                                '8' => return kb.KEY_END,
                                else => {
                                    std.debug.print("Only 5 or 6 are possible.", .{});
                                },
                            }
                        }
                    },
                    'A' => return kb.KEY_UP,
                    'B' => return kb.KEY_DOWN,
                    'C' => return kb.KEY_RIGHT,
                    'D' => return kb.KEY_LEFT,
                    'H' => return kb.KEY_HOME,
                    'F' => return kb.KEY_END,
                    else => {},
                }
            } else if (buf[0] == 'O') {
                switch (buf[1]) {
                    'H' => return kb.KEY_HOME,
                    'F' => return kb.KEY_END,
                    else => {},
                }
            }
            return '\x1b';
        } else {
            return buf[0];
        }
    }

    fn setStatusMessage(self: *Editor, msg: []const u8) !void {
        // There is some formatting magic in the tutorial version of this.
        // Would probably be nicer not to format string before every message, but it also
        // simpler to some extent.
        self.allocator.free(self.statusmsg);
        self.statusmsg = try self.allocator.dupe(u8, msg);
        self.statusmsg_time = std.time.timestamp();
    }

    fn search(self: *Editor, to_prompt: bool) !void {
        if (to_prompt) {
            const prompt = try self.get_prompt("Find: ");
            if (prompt) |query| {
                defer self.allocator.free(query);
                if (self.search_pattern) |sp| {
                    self.allocator.free(sp);
                }
                self.search_pattern = try self.allocator.dupe(u8, query);
            }
        }
        if (self.search_pattern) |sp| {
            try self.cur_buffer().search(sp);
        }
    }

    fn close_buffer(self: *Editor, forced: bool) !void {
        if (!forced) {
            if (self.cur_buffer().dirty > 0) {
                try self.setStatusMessage("You have unsaved changes. Add ! (bd!/q! if you want to quit or save).");
                return;
            }
        }
        // TODO: add command to delete by id. If empty, remove current.
        const buf = self.buffers.orderedRemove(self.cur_buffer_idx);
        buf.deinit();

        if (self.buffers.items.len == 0) {
            self.quit_flag = true;
            return;
        }
        self.next_buffer();
    }

    fn quit(self: *Editor, forced: bool) !void {
        const num_buffers = self.buffers.items.len;
        for (0..num_buffers) |_| {
            try self.close_buffer(forced);
        }
    }
};
