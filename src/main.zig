const std = @import("std");

pub fn main(_: std.process.Init) !void {
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
}
