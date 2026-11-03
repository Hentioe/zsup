const std = @import("std");
const Io = std.Io;
const Child = std.process.Child;
const Control = @import("Control.zig");
const Proc = @import("Proc.zig");
const Self = @This();

const log = std.log.scoped(.monitor);

pub const KillSource = enum { self, connector, unknown };

proc_ref: Proc.Ref,
control: *Control,
child: *Child,
future: ?Io.Future(void) = null,
kill_source: KillSource = .unknown,

pub fn init(proc_ref: Proc.Ref, child: *Child, control: *Control) Self {
    return Self{ .proc_ref = proc_ref, .child = child, .control = control };
}

pub fn deinit(self: *Self, io: Io) void {
    if (self.future) |*f| f.cancel(io);
}

pub fn start(self: *Self, io: Io) Io.ConcurrentError!void {
    std.debug.assert(self.future == null);
    self.future = try io.concurrent(launch, .{ self, io });
}

pub fn kill(self: *Self, io: Io) void {
    self.kill_source = .self;
    self.child.kill(io);
}

pub fn wait(self: *Self, io: Io) void {
    if (self.future) |*f| f.await(io);
}

fn launch(self: *Self, io: Io) void {
    log.debug("Launching monitor for {f}", .{self.proc_ref});
    defer if (self.kill_source == .unknown) { // 未知的击杀源，主动上报死亡
        log.warn("Child process died unexpectedly, reporting to supervisor", .{});
        self.control.send(io, self.proc_ref, .proc_dead_abnormal) catch |err| log.err("Monitor failed to send message: {}", .{err});
    };
    const term = self.child.wait(io) catch |err| {
        if (err != error.Canceled) log.err("Error waiting for child process: {}", .{err});
        return;
    };
    switch (term) {
        .exited => |status| {
            log.warn("Child process exited with status: {}", .{status});
        },
        .signal => |sig| {
            // .TERM    ->  进程被终止（默认）
            // .ABRT    ->  进程崩溃
            // .KILL    ->  进程被强制终止
            // .INT     ->  进程被中断（通常是 Ctrl+C，被 .exited 分支捕获）
            log.warn("Child process terminated by signal: {}", .{sig});
        },
        .stopped => |sig| {
            log.warn("Child process stopped by signal: {}", .{sig});
        },
        .unknown => |code| {
            log.warn("Child process terminated with unknown status code: {}", .{code});
        },
    }
}
