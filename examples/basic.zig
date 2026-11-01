const std = @import("std");
const zsup = @import("zsup");
const Argv = zsup.Argv;

pub fn main(init: std.process.Init) !void {
    var sup = zsup.init(init.io, init.gpa);
    defer sup.deinit();
    try sup.start();

    // 启动一个 ping 程序，3 秒后停止
    var ping_argv = try Argv.init(init.gpa, "ping");
    try ping_argv.addArgs(init.gpa, &.{ "-t", "99", "0.0.0.0" });
    const ping = try sup.launchOwned(ping_argv, .{});
    try init.io.sleep(.fromSeconds(3), .awake);
    try sup.stopProc(ping);
    std.log.info("Stopped ping: {f}", .{ping});

    // 启动一个会崩溃的程序
    const crash_argv = try Argv.init(init.gpa, "zig-out/bin/crash");
    const crash = try sup.launchOwned(crash_argv, .{
        .stderr_redirected = false, // 避免崩溃消息引起误解
        .stdout_redirected = false, // 同上
    });

    std.log.info("Restarting crash: {f}", .{crash});
    // 重启 crash
    _ = try sup.restartProc(crash);

    // 启动一个会生成子进程的程序
    const spawn_argv = try Argv.init(init.gpa, "zig-out/bin/spawn");
    const spawn = try sup.launchOwned(spawn_argv, .{});
    try init.io.sleep(.fromSeconds(1), .awake);
    try sup.stopProcSync(spawn, .fromSeconds(3));
    std.log.info("All spawn ping processes stopped", .{});
    try init.io.sleep(.fromSeconds(1), .awake);
    try sup.waitAll();
    std.log.info("Goodbye", .{});
}
