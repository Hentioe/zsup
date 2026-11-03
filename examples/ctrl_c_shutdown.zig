const std = @import("std");
const zsup = @import("zsup");
const posix = std.posix;
const Argv = zsup.Argv;

var should_exit: std.atomic.Value(bool) = .init(false);

pub fn main(init: std.process.Init) !void {
    var sup = try zsup.create(init.io, init.gpa);
    defer sup.destroy();
    try sup.start();
    var handle = sup.handle();

    // 启动一个持续运行的 ping 程序
    var ping_argv = try Argv.init(init.gpa, "ping");
    defer ping_argv.deinit(init.gpa);
    try ping_argv.addArgs(init.gpa, &.{ "-t", "99", "0.0.0.0" });
    _ = try handle.launch(&ping_argv, .{});

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

    while (!should_exit.load(.monotonic)) {
        try std.Io.sleep(init.io, .fromMilliseconds(50), .awake);
    }
}

// 信号处理函数，必须使用 C 调用约定
fn handleSignal(_: posix.SIG) callconv(.c) void {
    std.log.info("Signal received, exiting...", .{});
    should_exit.store(true, .monotonic);
}
