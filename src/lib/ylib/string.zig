const std = @import("std");

pub const String = struct {
    data: []u8,
    allocator: std.mem.Allocator,
    len: usize,

    pub fn init(size: usize, allocator: std.mem.Allocator) !*String {
        var self = try allocator.create(String);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.data = try self.allocator.alloc(u8, size);
        self.len = 0; // We allocate memory, but do not fill it yet.
        return self;
    }

    /// Clear the String content.
    /// This does not free/reallocate the memory, only resets the length counter
    /// so that memory is overwritten at next append().
    pub fn clear(self: *String) void {
        self.len = 0;
    }

    /// Append a u8 slice to the String.
    /// This copies the data.
    pub fn append(self: *String, other: []const u8) !void {
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

    /// Initialise from a u8 slice.
    pub fn fromSlice(chars: []const u8, allocator: std.mem.Allocator) !*String {
        var self = try String.init(chars.len, allocator);
        try self.append(chars);
        return self;
    }

    pub fn content(self: *String) []u8 {
        return self.data[0..self.len];
    }

    pub fn deinit(self: *String) void {
        self.allocator.free(self.data);
        self.allocator.destroy(self);
    }

    pub fn revert(self: *String) void {
        var tmp: u8 = undefined;
        const len = self.len;
        if (len == 0) {
            return;
        }
        for (0..len / 2) |i| {
            tmp = self.data[i];
            self.data[i] = self.data[len - 1 - i];
            self.data[len - 1 - i] = tmp;
        }
    }
};

test "append" {
    const allocator = std.testing.allocator;
    const x = try String.init(2, allocator);
    defer x.deinit();
    try x.append("a");
    try x.append("b");
    try std.testing.expect(x.len == 2);
    try std.testing.expect(std.mem.eql(u8, x.content(), "ab"));
}

test "clear" {
    const allocator = std.testing.allocator;
    const x = try String.fromSlice("42", allocator);
    defer x.deinit();
    x.clear();
    try std.testing.expect(x.len == 0);
    try std.testing.expect(std.mem.eql(u8, x.content(), ""));
}

test "revert" {
    const allocator = std.testing.allocator;
    const x = try String.init(2, allocator);
    defer x.deinit();
    x.revert();
    try std.testing.expect(x.len == 0);

    // Test odd number of chars.
    try x.append("123");
    x.revert();
    try std.testing.expect(std.mem.eql(u8, x.content(), "321"));
    x.clear();

    // Test even number of chars.
    try x.append("1234");
    x.revert();
    try std.testing.expect(std.mem.eql(u8, x.content(), "4321"));
    x.clear();
}
