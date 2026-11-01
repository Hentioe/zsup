const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Argv = @import("Argv.zig");
const Proc = @import("Proc.zig");
const Done = @import("Done.zig");
const Control = @import("Control.zig");
const errors = @import("errors.zig");
const Self = @This();

const Managed = struct {
    launch_options: LaunchOptions = .{},
    proc: *Proc,

    pub fn create(allocator: Allocator, proc: Proc) Allocator.Error!Managed {
        const ptr = try allocator.create(Proc);
        ptr.* = proc;
        return Managed{
            .proc = ptr,
        };
    }

    pub fn destroy(self: *Managed, allocator: Allocator) void {
        self.proc.deinit();
        allocator.destroy(self.proc);
        self.* = undefined;
    }

    pub fn stop(self: *Managed, io: Io) errors.SendError!void {
        if (!self.proc.stopping.load(.monotonic)) return self.send(io, .stop) // 仅在进程未执行过时发送停止消息
        else std.log.warn("Proc is already stopping: {f}", .{self.proc.ref});
    }

    pub fn send(self: *Managed, io: Io, message: Control.Message) errors.SendError!void {
        return self.proc.receiver.putOneUncancelable(io, message);
    }
};

const LaunchOptions = struct {
    stdout_redirected: bool = true,
    stderr_redirected: bool = true,
};

io: Io,
gpa: Allocator,
procs: std.AutoHashMap(u32, Managed),
mailbox: Control.Mail.Queue = .init(&.{}),
listener: ?Io.Future(void) = null,
waiting: bool = false,
exited: bool = false,

pub fn init(io: Io, gpa: Allocator) Self {
    return .{
        .io = io,
        .gpa = gpa,
        .procs = .init(gpa),
    };
}

pub fn deinit(self: *Self) void {
    std.log.debug("Deinitializing supervisor", .{});
    if (!self.exited) self.shutdown();
    var iter = self.procs.valueIterator();
    while (iter.next()) |m| m.destroy(self.gpa);
    self.procs.deinit();
    self.* = undefined;
}

pub fn start(self: *Self) Io.ConcurrentError!void {
    if (self.listener != null) return;
    self.listener = try self.io.concurrent(listen, .{self});
}

pub const HandleStatus = enum { normal, exit };

pub fn listen(self: *Self) void {
    while (true) {
        const mail = self.mailbox.getOneUncancelable(self.io) catch |err| {
            std.log.err("Supervisor failed to get mail: {s}", .{@errorName(err)});
            break;
        };
        var status: HandleStatus = .normal;
        if (std.meta.activeTag(mail) == .proc) status = self.handleProcMessage(mail.proc);
        if (std.meta.activeTag(mail) == .user) status = self.handleUserCommand(mail.user);

        switch (status) {
            .exit => break,
            .normal => {},
        }
    }
    std.log.debug("Supervisor exited", .{});
}

pub fn handleProcMessage(self: *Self, mail: Control.ProcMail) HandleStatus {
    switch (mail.message) {
        .stdout => |bytes| {
            if (self.procs.getPtr(mail.ref.pk)) |m| if (m.launch_options.stdout_redirected) {
                Io.File.stdout().writeStreamingAll(self.io, bytes.data) catch |err| std.log.err("Failed to write to stdout: {s}", .{@errorName(err)});
            };
        },
        .stderr => |bytes| {
            if (self.procs.getPtr(mail.ref.pk)) |m| if (m.launch_options.stderr_redirected) {
                Io.File.stderr().writeStreamingAll(self.io, bytes.data) catch |err| std.log.err("Failed to write to stderr: {s}", .{@errorName(err)});
            };
        },
        .proc_started => {
            if (self.procs.getPtr(mail.ref.pk)) |managed| {
                std.log.info("Started: {f}", .{managed.proc.ref});
            } else {
                std.log.err("Started but not found in procs map: {f}", .{mail.ref});
            }
        },
        .proc_dead => {
            std.log.warn("Dead: {f}", .{mail.ref});
            if (self.procs.fetchRemove(mail.ref.pk)) |kv| {
                var p = kv.value;
                p.destroy(self.gpa); // 销毁
            }
            std.debug.assert(self.procs.get(mail.ref.pk) == null);
            if (self.waiting and self.procs.count() == 0) {
                std.log.debug("All procs exited, supervisor exiting", .{});
                return .exit;
            }
        },
        .proc_lost => {
            // todo: 实现丢失连接的进程的处理
        },
        else => {},
    }

    return .normal;
}

pub fn handleUserCommand(self: *Self, mail: Control.UserMail) HandleStatus {
    switch (mail.command) {
        .wait_all => {
            if (self.procs.count() > 0) { // 如果还有进程在运行，标记为等待中，所有进程回收后会自动退出
                self.waiting = true;
            } else {
                return .exit;
            }
        },
        else => {},
    }

    return .normal;
}

pub fn launchOwned(self: *Self, argv: Argv, options: LaunchOptions) errors.LaunchError!Proc.Ref {
    const control: Control = .{ .queue = &self.mailbox };
    const proc = try Proc.initOwned(self.io, self.gpa, control, argv);
    var managed: Managed = try .create(self.gpa, proc);
    managed.launch_options = options;
    try self.procs.put(proc.ref.pk, managed);
    managed.proc.link() catch {
        // todo: 链接失败，可能需要上报 proc_lost 或采取其他处理措施。至少要满足：
        // - 从 procs 移除
        // - 终止任务、进程
        // - 释放 Proc
    };

    return proc.ref;
}

pub fn stopProc(self: *Self, ref: Proc.Ref) errors.StopError!void {
    if (self.procs.getPtr(ref.pk)) |managed| {
        try managed.stop(self.io);
        return;
    }

    return errors.StopError.ProcNotFound;
}

pub fn stopProcSync(self: *Self, ref: Proc.Ref, timeout: Io.Duration) errors.StopSyncError!void {
    if (self.procs.getPtr(ref.pk)) |managed| {
        std.log.debug("Sync stopping: {f}", .{ref});
        var done: *Done = try .create(self.gpa);
        defer if (done.state.load(.monotonic) != .timeout) done.destroy(self.gpa); // 没有超时，释放 done
        try managed.send(self.io, .{ .stop_sync = done });
        // 等待进程停止或超时
        done.event.waitTimeout(self.io, .{ .duration = .{ .clock = .awake, .raw = timeout } }) catch |err| {
            if (done.state.cmpxchgStrong(.pending, .timeout, .acq_rel, .acquire) == null) {
                // 确定进程不会回应，直接返回超时错误
                return err;
            } else {
                // 进程已经回应，继续等待
                try done.event.wait(self.io);
            }
        };

        return;
    }

    return errors.StopSyncError.ProcNotFound;
}

pub fn restartProc(self: *Self, ref: Proc.Ref) errors.RestartError!Proc.Ref {
    if (self.procs.get(ref.pk)) |managed| {
        const argv = try Argv.cloneFrom(self.gpa, &managed.proc.argv);
        const options = managed.launch_options;
        try self.stopProcSync(ref, .fromSeconds(3));
        return self.launchOwned(argv, options);
    }

    return errors.RestartError.ProcNotFound;
}

pub fn waitAll(self: *Self) errors.SendError!void {
    if (self.listener) |*f| {
        std.log.debug("Sending wait all command to supervisor", .{});
        try self.mailbox.putOneUncancelable(self.io, .{ .user = .{ .command = .wait_all } });
        f.await(self.io);
        self.listener = null; // 避免 shutdown 发消息
        self.exited = true;
    } else {
        std.log.warn("Supervisor not running", .{});
    }
}

pub fn shutdown(self: *Self) void {
    if (self.exited) return;
    var iter = self.procs.valueIterator();
    while (iter.next()) |managed| { // 向所有进程发送停止命令
        std.log.debug("Stopping managed proc: {f}", .{managed.proc.ref});
        managed.stop(self.io) catch continue;
    }
    self.waitAll() catch |err| std.log.err("Error waiting for all procs: {s}", .{@errorName(err)});
}
