//
//                     (/, .#
//                  ((//**,#((/#%.%%#//
//              &#%&#((%&%########((/,,,/
//           (#(@#(%%%%&&&%%%%######(((//,
//          %%%%&%%%%%#&&&%&%%#%%#####(((///
//       &&&&%#&#//&&&@@&&&&%%####((((((((//*,
//      %@&@&%&@(/(&&&@@&&&%%%###((((((((((////
//    .%&@&#%&(#%(/%&@@@@@&&%%%###((((((((/////*//
//   &&&@%(&&*#(#/%&@@@@@@&&%%%###((((((((((////*(*
//  #%&&%%#&/(/%#(@@@@@@&&%%%##(((((/((((///////,//
//  #%%%(#@(#(/*(@@@@@%%%%(/***//((/(((///**//(,**,*
//  &&&#%%@%((//&@@@%%%/@%(/(***/##(((**/////*/,,,*     - - - - - - - - - - - -
//  #&@%%#(##(#%@@@&%(#&%#/(((/(#&&%(*,////**,//(///   | Best text editor ever! |
// @&%#&@#*((*&@@@&&&&%%&#(((%&@@@@&(((/(//((((/((*     - - - - - - - - - - - -
//  %#&%%(&((#&@@&&&&%###%%%##@@&%(//**(##(((((/*,     /
//   &%#/(%&%@%@@&&&&%%%%#(((**,,,/**,**/((#((//      /
//    ###&@@&&%&&@@&&&%%#(((##%&&%(/##(((/(((/(/     /
//     /(&#(#@%&%(%&%#&##(&&@&&%(#((#/((((((/((*(   /
//       @&@&@(((##@&&%#&@&%#/*.......*,,/(/(/(//  /
//       &&&&@@&(#(@@#@&@##(*.*//////// .(((((((((
//       @&&#&@@###%##&##(,*((((##((((((/*(//((***
//        ,/&%#@(/(#&&&%#///((((##((///(/*//((((*
//         (#&@((,%%&&%%#((/((/#(///(**(/((*//((/
//       ,&&%&%#(@%&/&#((#(//(/(*/(#&%((**//((//
//      &&&&&&%%@@*/*%(##(((##(/&(%&/,(((/((**(
//      %&&&&&%%%@##*%##(#####&&(((,((((/(((((
//      &&&&&&&&&%%%&####((##&##(**(/*/((/(/,
//      %&&&&&%%%#%###(#%(((##(*//.*/(*,*/(/,
//       *%&%%#%#%%%%&(%%///,*%((((/(((,,,.(*
//         (%#(/%#%&%#%%/,*//,(#%(/(/(((.((/
//            /#%&%#%##////(#%(@%*,,*/*/.(
//                 /(/#(((/*/#****/*,/*.

const std = @import("std");
const config = @import("config.zig");
const row = @import("row.zig");
const editor = @import("editor.zig");
const str = @import("string.zig");
const posix = std.posix;

fn getWindowSize(writer: *const std.fs.File) ![2]usize {
    var ws: posix.winsize = undefined;
    const err = std.os.linux.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws));

    if (posix.errno(err) == .SUCCESS) {
        return .{ ws.row, ws.col };
    } else {
        // If ioctl failed, we will move cursor to the bottom right position and get its coordinates.
        try writer.writeAll("\x1b[999C\x1b[999B");
        return getCursorPosition(writer);
    }
}
fn getCursorPosition(writer: *const std.fs.File) ![2]usize {
    try writer.writeAll("\x1b[6n");
    const stdin = std.fs.File.stdin();
    var stdin_buffer: [1024]u8 = undefined;
    var reader = stdin.reader(&stdin_buffer);

    //[2..] because we get an escape sequence coming back.
    // It looks like 27[rows;colsR, we need to parse it.
    // var buf: [32]u8 = undefined;
    const line = try reader.interface.takeDelimiterExclusive('R');
    var tokenizer = std.mem.splitScalar(u8, line[2..], ';');

    // Have some default values in case this thing fails.
    const rows = try std.fmt.parseInt(usize, tokenizer.next() orelse "25", 10);
    const cols = try std.fmt.parseInt(usize, tokenizer.next() orelse "80", 10);

    return .{ rows, cols };
}


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
        const buf = try state.allocator.alloc(u8, total_len);
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
        const ws = try getWindowSize(writer);
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
        state.allocator.free(state.statusmsg);
    }
};
pub var state: Buffer = undefined;


pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer switch (gpa.deinit()) {
        .leak => std.debug.panic("Some memory leaked!", .{}),
        .ok => {},
    };

    const ed = try editor.Editor.init(gpa.allocator());
    defer ed.deinit();

    if (std.os.argv.len > 1) {
        try ed.open(std.mem.span(std.os.argv[1]));
    }

    while (true) {
        try ed.refreshScreen();
        const c = try editor.editorReadKey();
        const should_continue = try ed.processKeypress(c);
        if (!should_continue) {
            break;
        }
    }
}
