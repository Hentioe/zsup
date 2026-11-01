const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Argv = @import("Argv.zig");
const Proc = @import("Proc.zig");
const Control = @import("Control.zig");
const replies = @import("replies.zig");
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
            defer bytes.destroy(self.gpa);
            if (self.procs.getPtr(mail.ref.pk)) |m| if (m.launch_options.stdout_redirected) {
                Io.File.stdout().writeStreamingAll(self.io, bytes.data) catch |err| std.log.err("Failed to write to stdout: {s}", .{@errorName(err)});
            };
        },
        .stderr => |bytes| {
            defer bytes.destroy(self.gpa);
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
        .stop_proc => |payload| {
            var err: ?errors.StopError = null;
            if (self.procs.getPtr(payload.ref.pk)) |managed| {
                const message: Control.Message = if (payload.done) |done| .{ .stop_sync = done } else .stop;
                managed.send(self.io, message) catch |e| {
                    err = e;
                };
            } else {
                err = errors.StopError.ProcNotFound;
            }

            if (payload.done) |done| {
                // 此处的错误返回，建立在 reply 侧没有收到消息的基础上。否则会导致提前返回。
                // 目前，错误要么是 Proc 未找到，要么是发送失败，满足条件。
                if (err) |e| done.replyErr(self.io, e) else done.reply(self.io);
            } else {
                if (err) |e| std.log.warn("Failed to stop proc: {s}", .{@errorName(e)});
            }
        },
        .wait_all => {
            if (self.procs.count() > 0) { // 如果还有进程在运行，标记为等待中，所有进程回收后会自动退出
                self.waiting = true;
            } else {
                return .exit;
            }
        },
    }

    return .normal;
}

pub fn sendCommand(self: *Self, command: Control.Command) errors.SendError!void {
    try self.mailbox.putOneUncancelable(self.io, .{ .user = .{ .command = command } });
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

pub fn stopProc(self: *Self, ref: Proc.Ref) errors.SendError!void {
    return self.sendCommand(.{ .stop_proc = .{ .ref = ref, .done = null } });
}

pub fn stopProcSync(self: *Self, ref: Proc.Ref, timeout: Io.Duration) errors.StopSyncError!void {
    std.log.debug("Sync stopping: {f}", .{ref});
    var done: *replies.Done(errors.StopError) = try .create(self.gpa);
    defer done.release(self.gpa);
    done.retain(); // 即将发送出去，持有 +1
    self.sendCommand(.{ .stop_proc = .{ .ref = ref, .done = done } }) catch {
        done.release(self.gpa); // 发送失败，撤销
    };
    // 等待进程回应或超时
    done.event.waitTimeout(self.io, .{ .duration = .{ .clock = .awake, .raw = timeout } }) catch |err| {
        if (done.state.cmpxchgStrong(.pending, .timeout, .acq_rel, .acquire) == null) {
            return err; // 直接返回超时错误（reply 不会再调用）
        } else {
            try done.event.wait(self.io); // 进程已经回应，继续等待
        }
    };

    // 检查 done 中的错误
    if (done.err) |err| { // 虽然发送到了 Supervisor，但没有传递到 reply 侧
        if (err == errors.StopError.Closed or err == errors.StopError.ProcNotFound) done.release(self.gpa); // 撤销持有，因为 reply 侧没有收到消息
        return err;
    }

    return;
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
        managed.send(self.io, .stop) catch continue;
    }
    self.waitAll() catch |err| std.log.err("Error waiting for all procs: {s}", .{@errorName(err)});
}
