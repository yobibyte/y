const std = @import("std");
const row = @import("row.zig");
const main = @import("main.zig");
const term = @import("term.zig");

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
    statusmsg: []const u8,
    statusmsg_time: i64,
    // Can do with a bool now, but probably will be useful for tracking undo.
    // Probably, with the undo file, we can make it signed, but I will change it later.
    dirty: u64,
    confirm_to_quit: bool, // if set, quit without confirmation, reset when pressed Ctrl+Q once.
    stdout: *const std.fs.File,
    reader: *std.fs.File.Reader,
    comment_chars: []const u8,

    pub fn rowsToString(self: *Buffer) ![]u8 {
        var total_len: usize = 0;
        for (self.rows.items) |crow| {
            // 1 for the newline symbol.
            total_len += crow.content.len + 1;
        }
        const buf = try main.state.allocator.alloc(u8, total_len);
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

    pub fn reset(self: *Buffer, writer: *const std.fs.File, reader: *std.fs.File.Reader, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        self.cx = 0;
        self.rx = 0;
        self.cy = 0;
        self.rows = std.array_list.Managed(*row.Row).init(allocator);
        self.rowoffset = 0;
        self.coloffset = 0;
        const ws = try term.getWindowSize(writer);
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

    pub fn deinit(self: *Buffer) void {
        for (self.rows.items) |crow| {
            crow.deinit();
        }
        self.rows.deinit();
        if (self.filename) |fname| {
            self.allocator.free(fname);
        }
        main.state.allocator.free(main.state.statusmsg);
    }
};
