const std = @import("std");
const zsup = @import("zsup");

pub fn main(init: std.process.Init) !void {
    var sup = zsup.init(init.io, init.gpa);
    defer sup.deinit();
    sup.start();
    const ping = try sup.launch(&.{ "ping", "-t", "99", "0.0.0.0" }, .{});
    try init.io.sleep(.fromSeconds(3), .awake);
    std.log.info("Restarting ping process", .{});
    const ping2 = try sup.restartProc(ping);
    std.debug.assert(ping.pk != ping2.pk);
    try init.io.sleep(.fromSeconds(3), .awake);
}
