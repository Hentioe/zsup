const std = @import("std");

pub fn main(init: std.process.Init) !void {
    try init.io.sleep(.fromSeconds(1), .awake);
    @panic("Crash after 1 second");
}
