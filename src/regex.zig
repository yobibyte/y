//! Regex engine based on Rob Pike's implementation.
//! https://www.cs.princeton.edu/courses/archive/spr09/cos333/beautiful.html
//! This is very simple and elegant. If I want to do something more advanced, I can either add more stuff here or use sed that is available everywhere.

const std = @import("std");

// Building it step by step:
// ^ is beginning of a line.
// . is any symbol.
// --------WE ARE HERE------
// $ end of a line.
// * any number of a previous symbol.

pub fn match(regex: []const u8, text: []const u8) bool {
    // I consider empty regex non-matchable.
    if (regex.len > 0) {
        if (regex[0] == '^') {
            return match(regex[1..], text);
        }
        for (0..text.len) |start| {
            if (matchHere(regex, text[start..])) {
                return true;
            }
        }
    }
    return false;
}

pub fn matchHere(regex: []const u8, text: []const u8) bool {
    if (regex.len == 0) {
        return true;
    }
    if (text.len > 0 and (regex[0] == '.' or regex[0] == text[0])) {
        return matchHere(regex[1..], text[1..]);
    }
    return false;
}

test "match_no_special_chars" {
    try std.testing.expect(match("a", "a"));
}

test "no_match_no_special_chars" {
    try std.testing.expect(!match("a", "b"));
}
