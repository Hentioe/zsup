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
    defer ping_argv.deinit(init.gpa);
    try ping_argv.addArgs(init.gpa, &.{ "-t", "99", "0.0.0.0" });
    const ping = try handle.launch(&ping_argv, .{});
    try init.io.sleep(.fromSeconds(3), .awake);
    try handle.stopProc(ping);
    log.info("Stopped ping", .{});

    // 启动一个会崩溃的程序
    var crash_argv = try Argv.init(init.gpa, "zig-out/bin/crash");
    defer crash_argv.deinit(init.gpa);
    const crash = try handle.launch(&crash_argv, .{
        .stderr_redirected = false, // 避免崩溃消息引起误解
        .stdout_redirected = false, // 同上
    });

    log.info("Restarting crash: {f}", .{crash});
    // 重启 crash
    _ = try handle.restartProc(crash);

    // 启动一个会生成子进程的程序
    var spawn_argv = try Argv.init(init.gpa, "zig-out/bin/spawn");
    defer spawn_argv.deinit(init.gpa);
    const spawn = try handle.launch(&spawn_argv, .{});
    try init.io.sleep(.fromSeconds(1), .awake);
    try handle.stopProcSync(spawn, .fromSeconds(3));
    log.info("All spawn ping processes stopped", .{});
    try init.io.sleep(.fromSeconds(1), .awake);
    log.info("Goodbye", .{});
}
