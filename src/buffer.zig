const std = @import("std");
const row = @import("row.zig");
const main = @import("main.zig");
const config = @import("config.zig");
const str = @import("string.zig");
const kb = @import("kb.zig");
const common = @import("common.zig");

const zon: struct {
    name: enum { y },
    version: []const u8,
    fingerprint: u64,
    minimum_zig_version: []const u8,
    paths: []const []const u8,
} = @import("zon_mod");

const welcome_msg = "yobibyte's text editor, version " ++ zon.version ++ ".";

pub const Coord = struct {
    x: usize,
    y: usize,

    pub fn cmp(self: *Coord, other: *Coord) std.math.Order {
        if (self.y > other.y) {
            return .gt;
        }
        if (self.y < other.y) {
            return .lt;
        }
        if (self.x > other.x) {
            return .gt;
        }
        if (self.x < other.x) {
            return .lt;
        }
        return .eq;
    }
};

pub const Buffer = struct {
    allocator: std.mem.Allocator,
    screenrows: usize,
    screencols: usize,
    cx: usize,
    cy: usize, // y coordinate in the file frame of reference.
    rx: usize, // render x coordinate.
    rows: std.array_list.Managed(*row.Row),
    rowoffset: usize,
    coloffset: usize,
    filename: ?[]const u8,
    // Can do with a bool now, but probably will be useful for tracking undo.
    // Probably, with the undo file, we can make it signed, but I will change it later.
    dirty: u64,
    comment_chars: []const u8,
    sel_start: Coord,
    sel_end: Coord,

    pub fn len(self: *Buffer) usize {
        return self.rows.items.len;
    }

    pub fn reset_sel(self: *Buffer) void {
        self.sel_start.x = 0;
        self.sel_start.y = 0;
        self.sel_end.x = 0;
        self.sel_end.y = 0;
    }

    pub fn rowsToString(self: *Buffer) ![]u8 {
        var total_len: usize = 0;
        for (self.rows.items) |crow| {
            // 1 for the newline symbol.
            total_len += crow.content.len + 1;
        }
        const buf = try self.allocator.alloc(u8, total_len);
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

    pub fn init(allocator: std.mem.Allocator, screenrows: usize, screencols: usize, maybe_fname: ?[]const u8) !*Buffer {
        var self = try allocator.create(Buffer);
        self.allocator = allocator;
        self.cx = 0;
        self.rx = 0;
        self.cy = 0;
        self.rows = std.array_list.Managed(*row.Row).init(allocator);
        self.rowoffset = 0;
        self.coloffset = 0;
        self.filename = null;
        self.dirty = 0;
        self.comment_chars = "//";
        self.screenrows = screenrows;
        self.screencols = screencols;
        // For selection, x in the render space, y in the row space.
        self.sel_start = Coord{ .x = 0, .y = 0 };
        self.sel_end = Coord{ .x = 0, .y = 0 };

        if (maybe_fname) |fname| {
            self.filename = try self.allocator.dupe(u8, fname);

            const maybe_file = std.fs.cwd().openFile(fname, .{ .mode = .read_only }) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (maybe_file) |file| {
                defer file.close();

                var stdin_buffer: [1024]u8 = undefined;
                var reader = file.reader(&stdin_buffer);
                while (true) {
                    const line = reader.interface.takeDelimiterExclusive('\n') catch |err| {
                        switch (err) {
                            error.EndOfStream => break,
                            else => return err,
                        }
                    };
                    try self.insertRow(self.len(), line);
                }
                self.setCommentChars();
                // InsertRow calls above modify the dirty counter -> reset.
                self.dirty = 0;
            }
        }

        return self;
    }

    pub fn deinit(self: *Buffer) void {
        for (self.rows.items) |crow| {
            crow.deinit();
        }
        self.rows.deinit();
        if (self.filename) |fname| {
            self.allocator.free(fname);
        }
        self.allocator.destroy(self);
    }

    pub fn insertRow(self: *Buffer, at: usize, line: []u8) !void {
        if (at > self.len()) {
            return;
        }
        try self.rows.insert(at, try row.Row.init(line, self.allocator));

        try self.rows.items[at].update();
        self.dirty += 1;
    }

    pub fn delRow(self: *Buffer, at: ?usize) void {
        var row_idx: usize = undefined;
        if (at) |idx| {
            row_idx = idx;
        } else {
            row_idx = self.cy;
        }
        if (row_idx >= self.len()) {
            return;
        }
        const crow = self.rows.orderedRemove(row_idx);
        crow.deinit();
        if (row_idx == self.len()) {
            self.cy -= 1;
        }
        self.dirty += 1;
    }

    pub fn commentLine(self: *Buffer) !void {
        var to_comment = true;
        if (self.rows.items[self.cy].content.len >= self.comment_chars.len) {
            to_comment = !std.mem.startsWith(u8, self.rows.items[self.cy].content, self.comment_chars);
        }
        for (self.comment_chars, 0..) |cs, i| {
            if (to_comment) {
                try self.rows.items[self.cy].insertChar(cs, i);
                self.cx += 1;
            } else {
                try self.rows.items[self.cy].delChar(0);
                if (self.cx > 0) {
                    self.cx -= 1;
                }
            }
        }
        try self.rows.items[self.cy].update();
        self.dirty += 1;
    }

    pub fn scroll(self: *Buffer) void {
        self.rx = 0;
        if (self.cy < self.len()) {
            self.rx = self.rows.items[self.cy].cxToRx(self.cx);
        }

        if (self.cy < self.rowoffset) {
            self.rowoffset = self.cy;
        }
        if (self.cy >= self.rowoffset + self.screenrows) {
            self.rowoffset = self.cy - self.screenrows + 1;
        }
        if (self.rx < self.coloffset) {
            self.coloffset = self.rx;
        }
        if (self.rx >= self.coloffset + self.screencols) {
            self.coloffset = self.rx - self.screencols + 1;
        }
    }
    pub fn drawRows(self: *Buffer, str_buffer: *str.String, visual: bool) !void {
        for (0..self.screenrows) |crow| {
            const filerow = self.rowoffset + crow;
            // Erase in line, by default, erases everything to the right of cursor.
            if (filerow >= self.len()) {
                if (self.len() == 0 and crow == self.screenrows / 3) {
                    if (self.screencols - welcome_msg.len >= 0) {
                        const padding = (self.screencols - welcome_msg.len) / 2;
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
                const offset_row = self.rows.items[filerow].render;
                if (offset_row.len > self.coloffset) {
                    var maxlen = offset_row.len - self.coloffset;
                    if (maxlen > self.screencols) {
                        maxlen = self.screencols;
                    }
                    var crow_sel_start_rx: usize = 0;
                    var crow_sel_end_rx: usize = 0;
                    if (visual and self.sel_start.y <= filerow and filerow <= self.sel_end.y) {
                        if (filerow == self.sel_start.y) {
                            crow_sel_start_rx = self.sel_start.x;
                            if (filerow < self.sel_end.y) {
                                crow_sel_end_rx = self.coloffset + maxlen;
                            }
                        }
                        if (filerow == self.sel_end.y) {
                            crow_sel_end_rx = self.sel_end.x;
                            if (crow_sel_end_rx > self.coloffset + maxlen) {
                                crow_sel_end_rx = self.coloffset + maxlen;
                            }
                        }
                        if (self.sel_start.y < filerow and filerow < self.sel_end.y) {
                            crow_sel_start_rx = self.coloffset;
                            crow_sel_end_rx = self.coloffset + maxlen;
                        }

                        //TODO checks?
                        try str_buffer.append(offset_row[self.coloffset..crow_sel_start_rx]);
                        try str_buffer.append("\x1b[7m");
                        if (maxlen == 0) {
                            //TODO: simplify?
                            try str_buffer.append(" ");
                        } else {
                            if (offset_row.len >= self.coloffset) {
                                try str_buffer.append(offset_row[crow_sel_start_rx..crow_sel_end_rx]);
                            }
                        }
                        try str_buffer.append("\x1b[0m");
                        try str_buffer.append(offset_row[crow_sel_end_rx .. self.coloffset + maxlen]);
                    } else {
                        if (offset_row.len >= self.coloffset) {
                            try str_buffer.append(offset_row[self.coloffset .. self.coloffset + maxlen]);
                        }
                    }
                }
            }
            try str_buffer.append("\x1b[K");
            try str_buffer.append("\r\n");
        }
    }

    pub fn moveCursor(self: *Buffer, key: u16, mode: common.Mode) void {
        switch (key) {
            // TODO: do the boundary checks, there's a chance we do +=1 and go beyond rx here.
            kb.KEY_LEFT => {
                if (self.cx > 0) {
                    self.cx -= 1;
                    if (mode == common.Mode.visual) {
                        self.sel_end.x -= 1;
                    }
                }
            },
            kb.KEY_DOWN => {
                if (self.cy < self.len() - 1) {
                    self.cy += 1;
                    if (mode == common.Mode.visual) {
                        self.sel_end.y += 1;
                        self.sel_end.x = self.rx;
                    }
                }
            },
            kb.KEY_UP => {
                if (self.cy > 0) {
                    self.cy -= 1;
                    if (mode == common.Mode.visual) {
                        self.sel_end.y -= 1;
                        self.sel_end.x = self.rx;
                    }
                }
            },
            kb.KEY_RIGHT => {
                // Should we check -1 in insert here?
                if (self.cy < self.len()) {
                    if (self.cx < self.rows.items[self.cy].content.len) {
                        self.cx += 1;
                        if (mode == common.Mode.visual) {
                            self.sel_end.x += 1;
                        }
                    }
                }
            },
            kb.KEY_HOME => {
                self.cx = 0;
            },
            kb.KEY_END => {
                if (self.cy < self.len()) {
                    self.cx = self.rows.items[self.cy].content.len - 1;
                }
                if (mode == common.Mode.insert) {
                    self.cx += 1;
                }
            },
            else => return,
        }

        const rowlen = if (self.cy < self.len()) self.rows.items[self.cy].content.len else 0;
        if (self.cx > rowlen) {
            self.cx = rowlen;
        }
    }

    pub fn setCommentChars(self: *Buffer) void {
        const fname = self.filename orelse return;
        if (std.mem.endsWith(u8, fname, ".py")) {
            self.comment_chars = "#";
        }
    }

    pub fn insertChar(self: *Buffer, c: u8) !void {
        if (self.cy == self.len()) {
            try self.insertRow(self.cy, "");
        }
        try self.rows.items[self.cy].insertChar(c, self.cx);
        self.cx += 1;
    }

    pub fn delCharToLeft(self: *Buffer) !void {
        if (self.cy == self.len()) {
            return;
        }
        if (self.cx == 0 and self.cy == 0) {
            return;
        }
        // How can it be smaller than zero?
        const crow = &self.rows.items[self.cy];
        if (self.cx > 0) {
            try crow.*.delChar(self.cx - 1);
            self.cx -= 1;
        } else {
            // Move cursor to the joint of two new rows.
            var prev_row = self.rows.items[self.cy - 1];
            self.cx = prev_row.content.len;
            // Join the two rows.
            try prev_row.append(self.rows.items[self.cy].content);
            self.delRow(null); // Remove the current row
            self.cy -= 1; // Move cursor up.
        }
        try crow.*.update();
        self.dirty += 1;
    }

    pub fn insertNewLine(self: *Buffer) !void {
        if (self.cx == 0) {
            try self.insertRow(self.cy, "");
        } else {
            const crow = &self.rows.items[self.cy];
            try self.insertRow(self.cy + 1, crow.*.content[self.cx..]);
            crow.*.content = crow.*.content[0..self.cx];
            try crow.*.update();
        }
        self.cy += 1;
        self.cx = 0;
    }

    pub fn search(self: *Buffer, query: []const u8) !void {
        const start_idx = self.cy;
        var cur_idx = self.cy;
        var search_start_x = @min(self.rx + 1, self.rows.items[cur_idx].render.len);
        while (true) {
            const crow = &self.rows.items[cur_idx];
            const maybe_match_idx = std.mem.indexOf(u8, crow.*.render[search_start_x..], query);
            if (maybe_match_idx) |match| {
                self.cy = cur_idx;
                self.cx = crow.*.rxToCx(match) + search_start_x;
                if (self.len() - cur_idx > self.screenrows) {
                    self.rowoffset = self.len();
                }
                break;
            }
            search_start_x = 0;
            if (cur_idx == self.len() - 1) {
                cur_idx = 0;
            } else {
                cur_idx += 1;
            }
            if (cur_idx == start_idx) {
                break;
            }
        }
    }

    pub fn goToNextWord(self: *Buffer) void {
        var prev_char: u8 = undefined;
        var cur_char: u8 = undefined;
        if (self.rows.items[self.cy].content.len > 0) {
            prev_char = self.rows.items[self.cy].content[self.cx];
            cur_char = self.rows.items[self.cy].content[self.cx];
        } else {
            prev_char = ' ';
            cur_char = ' ';
        }

        while (true) {
            if (self.cx + 2 <= self.rows.items[self.cy].content.len) {
                self.cx += 1;
            } else {
                self.cx = 0;
                self.cy += 1;
                prev_char = ' ';
            }
            // FIXME if we have a row longer than screencols, we crash here.
            if (self.cy == self.rows.items.len) {
                self.cy -= 1;
                return;
            }
            // FIXME we do not stop at the end of the file but iterate on the last row circularly.
            if (self.rows.items[self.cy].content.len > 0) {
                cur_char = self.rows.items[self.cy].content[self.cx];
                if (prev_char == ' ' and cur_char != ' ') {
                    return;
                }
                prev_char = cur_char;
            }
        }
    }
};
