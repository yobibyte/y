const std = @import("std");
const main = @import("main.zig");
const config = @import("config.zig");

pub const Row = struct {
    content: []u8,
    render: []u8,
    allocator: std.mem.Allocator,

    pub fn init(content: []u8, allocator: std.mem.Allocator) !*Row {
        var self = try allocator.create(Row);
        self.allocator = allocator;
        self.content = try self.allocator.dupe(u8, content);
        self.render = try self.allocator.dupe(u8, content);
        try self.update();
        return self;
    }

    pub fn update(self: *Row) !void {
        var tabs: usize = 0;
        for (self.content) |c| {
            if (c == '\t') {
                tabs += 1;
            }
        }
        // We already have 1 byte in the content, subtract from the width.
        // This is the maximum number of memory we'll use.
        self.allocator.free(self.render);
        self.render = try self.allocator.alloc(u8, self.content.len + tabs * (config.TAB_WIDTH - 1));
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
    pub fn cxToRx(self: *Row, cx: usize) usize {
        var rx: usize = 0;

        for (self.content[0..cx]) |c| {
            if (c == '\t') {
                rx += (config.TAB_WIDTH - 1) - (rx % config.TAB_WIDTH);
            }
            rx += 1;
        }

        return rx;
    }

    pub fn insertChar(self: *Row, c: u8, at: usize) !void {
        // I am not sure why the original tutorial used an int here.
        // I will use a unsigned int here.
        const oldsize = self.content.len;
        var actual_at = at;
        if (at > oldsize) {
            actual_at = oldsize;
        }
        // I didn'make reallocate work. Figure this out.
        // Probably after switch to the gpa.
        // self.content = self.allocator.reallocate(self.content, oldsize+1);

        const new_content = try self.allocator.alloc(u8, oldsize + 1);

        if (actual_at > 0) {
            std.mem.copyForwards(u8, new_content[0..actual_at], self.content[0..actual_at]);
        }
        new_content[actual_at] = c;
        if (actual_at < oldsize) {
            std.mem.copyForwards(u8, new_content[actual_at + 1 ..], self.content[actual_at..]);
        }
        self.allocator.free(self.content);
        self.content = new_content;

        try self.update();
    }

    pub fn delChar(self: *Row, at: usize) !void {
        const rowlen = self.content.len;
        if (at >= rowlen) {
            return;
        }
        std.mem.copyForwards(u8, self.content[at..], self.content[at + 1 .. rowlen]);
        self.content = try self.allocator.realloc(self.content, rowlen - 1);
    }

    pub fn append(self: *Row, chunk: []u8) !void {
        const new_content = try self.allocator.alloc(u8, self.content.len + chunk.len);
        std.mem.copyForwards(u8, new_content[0..self.content.len], self.content);
        std.mem.copyForwards(u8, new_content[self.content.len..], chunk);
        // TODO: be careful when using gpa.
        self.allocator.free(self.content);
        self.content = new_content;
        try self.update();
    }

    pub fn deinit(self: *Row) void {
        self.allocator.free(self.render);
        self.allocator.free(self.content);
        self.allocator.destroy(self);
    }
};
