const std = @import("std");
const zsup = @import("zsup");

pub fn main(init: std.process.Init) !void {
    var sup = zsup.init(init.io, init.gpa);
    defer sup.deinit();
    sup.start();

    // 启动一个 ping 程序，3 秒后停止
    const ping = try sup.launch(&.{ "ping", "-t", "99", "0.0.0.0" }, .{});
    try init.io.sleep(.fromSeconds(3), .awake);
    try sup.stopProc(ping);
    std.log.info("Stopped ping: {f}", .{ping});

    // 启动一个会崩溃的程序
    const crash = try sup.launch(&.{"zig-out/bin/crash"}, .{
        .stderr_redirected = false, // 避免崩溃消息引起误解
        .stdout_redirected = false, // 同上
    });

    std.log.info("Restarting crash: {f}", .{crash});
    // 重启 crash
    _ = try sup.restartProc(crash);

    // 启动一个会生成子进程的程序
    const spawn = try sup.launch(&.{"zig-out/bin/spawn"}, .{});
    try init.io.sleep(.fromSeconds(1), .awake);
    try sup.stopProcSync(spawn, .fromSeconds(3));
    std.log.info("All spawn ping processes stopped", .{});
    try init.io.sleep(.fromSeconds(1), .awake);
    try sup.waitAll();
    std.log.info("Goodbye", .{});
}
