const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    var group: Io.Group = .init;

    group.async(init.io, launch, .{ init.io, init.gpa });
    group.async(init.io, launch, .{ init.io, init.gpa });
    group.async(init.io, launch, .{ init.io, init.gpa });
    group.async(init.io, launch, .{ init.io, init.gpa });
    group.async(init.io, launch, .{ init.io, init.gpa });
    group.async(init.io, launch, .{ init.io, init.gpa });
    group.async(init.io, launch, .{ init.io, init.gpa });
    group.async(init.io, launch, .{ init.io, init.gpa });
    group.async(init.io, launch, .{ init.io, init.gpa });
    try group.await(init.io);
}

pub fn launch(io: Io, allocator: Allocator) void {
    _ = std.process.run(allocator, io, .{
        .argv = &.{ "ping", "-t", "99", "0.0.0.0" },
    }) catch |err| std.log.err("Failed to run process: {}", .{err});
}
