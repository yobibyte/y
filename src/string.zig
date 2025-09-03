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

    pub fn content(self: *String) []u8 {
        return self.data[0..self.len];
    }

    pub fn deinit(self: *String) void {
        self.allocator.free(self.data);
        self.allocator.destroy(self);
    }
};
