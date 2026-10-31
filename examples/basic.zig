const std = @import("std");
const zsup = @import("zsup");

pub fn main(init: std.process.Init) !void {
    var sup = zsup.init(init.io, init.gpa);
    defer sup.deinit();
    sup.start();
    const ping = try sup.launch(&.{ "ping", "-t", "99", "0.0.0.0" }, .{});
    // 等待 3 秒
    try init.io.sleep(.fromSeconds(3), .awake);
    // 停止 ping 进程
    try sup.stopProc(ping);
    std.log.info("Stopped ping: {f}", .{ping});
    const crash = try sup.launch(&.{"zig-out/bin/crash"}, .{
        .stderr_redirected = false, // 避免崩溃消息引起误解
        .stdout_redirected = false, // 同上
    });
    std.log.info("Waiting for crash: {f}", .{crash});
    const spawn = try sup.launch(&.{"zig-out/bin/spawn"}, .{});
    try init.io.sleep(.fromSeconds(1), .awake);
    try sup.stopProc(spawn);
    std.log.info("All spawn ping processes stopped", .{});
    try init.io.sleep(.fromSeconds(1), .awake);
    try sup.waitAll();
    std.log.info("Goodbye", .{});
}
