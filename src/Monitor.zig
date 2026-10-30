const std = @import("std");
const Io = std.Io;
const Child = std.process.Child;
const Control = @import("Control.zig");
const Proc = @import("Proc.zig");
const Self = @This();

proc_ref: Proc.Ref,
control: *Control,

pub fn launch(self: *Self, io: Io, child: *Child) void {
    std.log.debug("Launching monitor for {f}", .{self.proc_ref});
    // 是否异常死亡
    var need_report: bool = false;
    defer if (need_report) self.control.send(io, self.proc_ref, .proc_dead);
    const term = child.wait(io) catch |err| {
        if (err != error.Canceled) std.log.err("Error waiting for child process: {}", .{err});
        return;
    };
    switch (term) {
        .exited => |status| {
            std.log.warn("Child process exited with status: {}", .{status});
            need_report = true; // 即使是 0，通过信号发送的也需要主动上报死亡
        },
        .signal => |sig| {
            // .TERM    ->  进程被终止（默认）
            // .ABRT    ->  进程崩溃
            // .KILL    ->  进程被强制终止
            // .INT     ->  进程被中断（通常是 Ctrl+C，被 .exited 分支捕获）
            std.log.warn("Child process terminated by signal: {}", .{sig});
            need_report = true;
        },
        .stopped => |sig| {
            std.log.warn("Child process stopped by signal: {}", .{sig});
            need_report = true;
        },
        .unknown => |code| {
            std.log.warn("Child process terminated with unknown status code: {}", .{code});
            need_report = true;
        },
    }
}
