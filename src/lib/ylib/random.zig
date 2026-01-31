const std = @import("std");

/// Get random seed.
fn seed() u64 {
    var s: u64 = undefined;
    std.posix.getrandom(std.mem.asBytes(&s)) catch |err| {
        std.debug.print("Failed to get random seed: {}\n", .{err});
        return 0;
    };
    return s;
}

// TODO: make this generic.
pub fn getF64() f64 {
    var prng = std.Random.DefaultPrng.init(seed());
    return prng.random().float(f64);
}

test "seed_difference" {
    try std.testing.expect(seed() != seed());
}

test "f64_difference" {
    try std.testing.expect(getF64() != getF64());
}
