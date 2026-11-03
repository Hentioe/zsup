const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Managed = @import("Managed.zig");
const Control = @import("Control.zig");
const Recipe = @import("Recipe.zig");
const Handle = @import("Handle.zig");
const Procs = std.AutoHashMap(u32, Managed);
const errors = @import("errors.zig");
const StartError = errors.StartError;
const Self = @This();

const log = std.log.scoped(.supervisor);

pub const State = enum(u8) { not_started, starting, working, closing };

io: Io,
gpa: Allocator,
mailbox: Control.Mail.Queue = .init(&.{}),
listener: ?Io.Future(void) = null,
state: std.atomic.Value(State) = .init(.not_started),

pub fn create(io: Io, gpa: Allocator) Allocator.Error!*Self {
    const ptr = try gpa.create(Self);
    ptr.* = .{ .io = io, .gpa = gpa };
    return ptr;
}

pub fn destroy(self: *Self) void {
    log.debug("Deinitializing supervisor", .{});
    if (self.state.load(.monotonic) != .not_started) self.shutdown();
    self.gpa.destroy(self);
}

/// 启动 Supervisor，启动后可处理 `Handle` 的任意调用。若不是 `not_started` 状态，会返回错误。
pub fn start(self: *Self) StartError!void {
    if (self.state.cmpxchgStrong(.not_started, .starting, .acq_rel, .acquire)) |current| {
        switch (current) {
            .starting, .closing => return StartError.Busy,
            .working => return StartError.AlreadyStarted,
            .not_started => unreachable,
        }
        return;
    }
    self.listener = self.io.concurrent(listen, .{self}) catch |err| {
        self.state.store(.not_started, .monotonic);
        return err;
    };
    self.state.store(.working, .monotonic);
}

/// 关闭 Supervisor。此调用会向所有进程发送关闭消息，并等待全部进程退出。完成后状态置为 `not_started`，可再次 `start()`。
pub fn shutdown(self: *Self) void {
    while (self.state.cmpxchgStrong(.working, .closing, .acq_rel, .acquire)) |current| {
        switch (current) {
            .not_started => return,
            .starting, .closing => continue,
            .working => unreachable,
        }
    }
    // 发送关闭消息
    self.mailbox.putOneUncancelable(self.io, .{ .user = .{ .command = .shutdown } }) catch |err| {
        if (err == Io.QueueClosedError.Closed) log.warn("Supervisor mailbox closed", .{});
    };
    if (self.listener) |*f| f.await(self.io); // 等待结束
    self.listener = null;
    self.state.store(.not_started, .monotonic);
    log.info("Supervisor shutdown complete", .{});
}

/// 生成一个 `Handle`，用于和 Supervisor 交互。`Handle` 实例不持有状态，可安全复制。
pub fn handle(self: *Self) Handle {
    return .{ .io = self.io, .gpa = self.gpa, .sup = self };
}

pub const HandleReturn = enum { normal, exit };

fn listen(self: *Self) void {
    var procs: Procs = .init(self.gpa);
    while (true) {
        const mail = self.mailbox.getOneUncancelable(self.io) catch |err| {
            log.err("Supervisor failed to get mail: {s}", .{@errorName(err)});
            break;
        };
        var status: HandleReturn = .normal;
        if (std.meta.activeTag(mail) == .proc) status = self.handleProcMessage(&procs, mail.proc);
        if (std.meta.activeTag(mail) == .user) status = self.handleUserCommand(&procs, mail.user);

        switch (status) {
            .exit => break,
            .normal => continue,
        }
    }
    log.debug("Listener is about to exit", .{});
    var iter = procs.valueIterator();
    while (iter.next()) |m| m.deinit(self.gpa); // 避免进程遗留，再调用一遍 deinit
    procs.deinit();
}

fn handleProcMessage(self: *Self, procs: *Procs, mail: Control.ProcMail) HandleReturn {
    switch (mail.message) {
        .stdout => |bytes| {
            defer bytes.destroy(self.gpa);
            if (procs.getPtr(mail.ref.pk)) |m| if (m.options.stdout_redirected) {
                Io.File.stdout().writeStreamingAll(self.io, bytes.data) catch |err| log.err("Failed to write to stdout: {s}", .{@errorName(err)});
            };
        },
        .stderr => |bytes| {
            defer bytes.destroy(self.gpa);
            if (procs.getPtr(mail.ref.pk)) |m| if (m.options.stderr_redirected) {
                Io.File.stderr().writeStreamingAll(self.io, bytes.data) catch |err| log.err("Failed to write to stderr: {s}", .{@errorName(err)});
            };
        },
        .proc_started => {
            if (procs.getPtr(mail.ref.pk)) |managed| {
                log.info("Started: {f}", .{managed.proc.ref});
            } else {
                log.err("Started but not found in procs map: {f}", .{mail.ref});
            }
        },
        .proc_dead, .proc_dead_abnormal => {
            log.warn("Dead: {f}", .{mail.ref});
            if (procs.fetchRemove(mail.ref.pk)) |kv| {
                var m = kv.value;
                m.deinit(self.gpa); // 销毁
            }
            std.debug.assert(procs.get(mail.ref.pk) == null);
            if (self.state.load(.monotonic) == .closing and procs.count() == 0) {
                log.info("All procs dead, supervisor exiting", .{});
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

fn handleUserCommand(self: *Self, procs: *Procs, mail: Control.UserMail) HandleReturn {
    switch (mail.command) {
        .proc_created => |payload| {
            payload.managed.proc.link() catch {
                // todo: 链接失败，可能需要上报 proc_lost 或采取其他处理措施。至少要满足：
                // - 从 procs 移除
                // - 终止任务、进程
                // - 释放 Proc
                payload.done.replyErr(self.io, errors.LaunchError.LinkFailed);
                return .normal;
            };
            if (procs.put(payload.managed.proc.ref.pk, payload.managed)) {
                payload.done.reply(self.io);
            } else |err| {
                payload.done.replyErr(self.io, err);
            }

            payload.done.release(self.gpa);
        },
        .stop_proc => |payload| {
            var err: ?errors.StopError = null;
            if (procs.getPtr(payload.ref.pk)) |managed| {
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
                if (err) |e| done.replyErr(self.io, e);
            } else {
                if (err) |e| log.warn("Failed to stop proc: {s}", .{@errorName(e)});
            }
        },
        .get_recipe => |payload| {
            if (procs.get(payload.ref.pk)) |managed| {
                const recipe: Recipe = .{ .argv = &managed.proc.argv, .options = managed.options };
                // 不需要 CAS，默认 Supervisor 的存活周期大于客户端调用
                // todo: 在此处克隆一份 recipe
                payload.done.replyResult(self.io, recipe);
                payload.done.release(self.gpa);
                std.debug.assert(payload.done.result != null);
            } else {
                payload.done.replyErr(self.io, errors.GetProcError.ProcNotFound);
            }
        },
        .shutdown => {
            if (procs.count() == 0) return .exit;

            // 如果还有进程在运行，逐个发送停止消息
            var iter = procs.valueIterator();
            while (iter.next()) |managed| {
                log.debug("Stopping managed proc: {f}", .{managed.proc.ref});
                managed.proc.receiver.putOneUncancelable(self.io, .stop) catch |err| {
                    if (err == Io.QueueClosedError.Closed) {
                        // todo: 如果已关闭，表示进程失联。丢给失联队列处理
                    }
                    continue;
                };
            }
        },
    }

    return .normal;
}
