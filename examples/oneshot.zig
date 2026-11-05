const std = @import("std");
const zsup = @import("zsup");
const Argv = zsup.Argv;

const log = std.log.scoped(.main);

pub fn main(init: std.process.Init) !void {
    var sup = try zsup.create(init.io, init.gpa);
    defer sup.destroy();
    try sup.start();
    var handle = sup.handle();

    // 启动一次性任务
    var argv = try Argv.init(init.gpa, "ls");
    defer argv.deinit(init.gpa);
    _ = try handle.launch(&argv, .{
        .cwd = try .allocPath(init.gpa, "/home"), // 设置 cwd
    });
    try init.io.sleep(.fromSeconds(1), .awake);

    log.info("Goodbye", .{});
}
