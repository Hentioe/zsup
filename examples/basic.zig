const std = @import("std");
const zsup = @import("zsup");
const Argv = zsup.Argv;

const log = std.log.scoped(.main);

pub fn main(init: std.process.Init) !void {
    var sup = try zsup.create(init.io, init.gpa);
    defer sup.destroy();
    try sup.start();
    var handle = sup.handle();

    // 启动一个 ping 程序，3 秒后停止
    var ping_argv = try Argv.init(init.gpa, "ping");
    try ping_argv.addArgs(init.gpa, &.{ "-t", "99", "0.0.0.0" });
    const ping = try handle.launchOwned(ping_argv, .{});
    try init.io.sleep(.fromSeconds(3), .awake);
    try handle.stopProc(ping);
    log.info("Stopped ping", .{});

    // 启动一个会崩溃的程序
    const crash_argv = try Argv.init(init.gpa, "zig-out/bin/crash");
    const crash = try handle.launchOwned(crash_argv, .{
        .stderr_redirected = false, // 避免崩溃消息引起误解
        .stdout_redirected = false, // 同上
    });

    log.info("Restarting crash: {f}", .{crash});
    // 重启 crash
    _ = try handle.restartProc(crash);

    // 启动一个会生成子进程的程序
    const spawn_argv = try Argv.init(init.gpa, "zig-out/bin/spawn");
    const spawn = try handle.launchOwned(spawn_argv, .{});
    try init.io.sleep(.fromSeconds(1), .awake);
    try handle.stopProcSync(spawn, .fromSeconds(3));
    log.info("All spawn ping processes stopped", .{});
    try init.io.sleep(.fromSeconds(1), .awake);
    log.info("Goodbye", .{});
}
