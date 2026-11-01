const std = @import("std");
const zsup = @import("zsup");
const Argv = zsup.Argv;

pub fn main(init: std.process.Init) !void {
    var sup = zsup.init(init.io, init.gpa);
    defer sup.deinit();
    sup.start();
    var ping_argv = try Argv.init(init.gpa, "ping");
    try ping_argv.addArgs(init.gpa, &.{ "-t", "99", "0.0.0.0" });
    const ping_ref = try sup.launchOwned(ping_argv, .{});
    try init.io.sleep(.fromSeconds(3), .awake);
    std.log.info("Restarting ping process", .{});
    const ping2 = try sup.restartProc(ping_ref);
    std.debug.assert(ping_ref.pk != ping2.pk);
    try init.io.sleep(.fromSeconds(1), .awake);
}
