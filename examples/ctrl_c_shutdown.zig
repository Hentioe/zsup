const std = @import("std");
const zsup = @import("zsup");
const posix = std.posix;

var should_exit = false;

pub fn main(init: std.process.Init) !void {
    var sup = zsup.init(init.io, init.gpa);
    defer sup.deinit();
    sup.start();
    _ = try sup.launch(&.{ "ping", "-t", "99", "0.0.0.0" }, .{});
    // 配置 Sigaction 结构体
    const action: posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };

    // 注册 SIGINT (Ctrl+C) 和 SIGTERM 的处理函数
    posix.sigaction(posix.SIG.INT, &action, null);
    posix.sigaction(posix.SIG.TERM, &action, null);

    std.log.info("Signal handlers registered. Press Ctrl+C to exit", .{});

    while (!should_exit) {
        try std.Io.sleep(init.io, .fromMilliseconds(50), .awake);
    }
}

// 信号处理函数，必须使用 C 调用约定
fn handleSignal(_: posix.SIG) callconv(.c) void {
    std.log.info("Signal received, exiting...", .{});
    should_exit = true;
}
