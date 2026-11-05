const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Child = std.process.Child;
const Control = @import("Control.zig");
const Recipe = @import("Recipe.zig");
const Future = std.Io.Future;
const Monitor = @import("Monitor.zig");
const Reporter = @import("Reporter.zig");
const Self = @This();

const log = std.log.scoped(.zsup_proc);

pub const Ref = struct {
    pub const Value = std.atomic.Value(u32);
    pub var counter: Value = .init(0);

    pk: u32,
    pid: ?Child.Id,

    pub fn new(pid: ?Child.Id) Ref {
        const pk = counter.fetchAdd(1, .monotonic);
        return .{ .pk = pk, .pid = pid };
    }

    pub fn format(self: *const Ref, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.pid) |pid| {
            try writer.print("pk={d},pid={d}", .{ self.pk, pid });
        } else {
            try writer.print("pk={d}", .{self.pk});
        }
    }
};

io: Io,
allocator: Allocator,
ref: Ref,
child: Child,
stopping: std.atomic.Value(bool),
control: Control,
connector: ?Future(ConnectError!void) = null,
monitor: ?Monitor = null,
reporter: ?Reporter = null,
reporters: Io.Group = .init,
receiver: Control.Message.Queue = .init(&.{}),

pub const InitError = std.process.SpawnError;

pub fn create(io: Io, allocator: Allocator, control: Control, recipe: *const Recipe) InitError!*Self {
    const ptr = try allocator.create(Self);
    errdefer allocator.destroy(ptr);
    const cwd = recipe.options.cwd.toChildCwd();
    const child = try std.process.spawn(io, .{
        .argv = recipe.argv.data.items,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd = cwd,
        .pgid = 0,
    });
    const ref = Ref.new(child.id);
    ptr.* = .{
        .ref = ref,
        .child = child,
        .io = io,
        .stopping = .init(false),
        .allocator = allocator,
        .control = control,
    };

    return ptr;
}

pub fn destroy(self: *Self) void {
    // todo: 输出取消后的结果
    log.debug("Destroying: {f}", .{self.ref});
    if (self.connector) |*f| {
        f.cancel(self.io) catch |err| log.warn("Connect cancel failed: {}", .{err});
    }
    if (self.monitor) |*monitor| {
        monitor.kill(self.io); // 先尝试杀掉子进程
        monitor.wait(self.io); // 等待监视器完成
        monitor.deinit(self.io); // 确保监视器销毁
    }
    self.reporters.cancel(self.io); // 注意：要保证 connect 没有运行（避免同时调用 group.cancel）。
    log.debug("Destroyed: {f}", .{self.ref});
    self.* = undefined;
}

pub fn link(self: *Self) Io.ConcurrentError!void {
    if (self.connector != null) {
        log.warn("Already linked ({f})", .{self.ref});
        return;
    }
    self.monitor = Monitor.init(self.ref, &self.child, &self.control);
    self.reporter = .{ .proc_ref = self.ref, .control = &self.control };
    self.connector = try self.io.concurrent(connect, .{self});
}

const Pgid = std.posix.pid_t;
const ConnectError = std.Io.ConcurrentError;

fn connect(self: *Self) ConnectError!void {
    // 正常情况，进入 receiver 消息处理后，不应该返回错误。
    // 如果返回了错误，表示在前置阶段就失败了。进程可能进入“失控”状态。上报为 proc_lost（丢失连接）
    errdefer self.control.send(self.io, self.ref, .proc_lost) catch |err| log.err("Failed to send lost message: {}", .{err});

    const io = self.io;
    const allocator = self.allocator;
    const child = &self.child;
    const monitor = &self.monitor.?;
    const reporter = &self.reporter.?;
    const receiver = &self.receiver;

    var pgid: ?Pgid = null;
    if (builtin.os.tag != .windows) if (child.id) |pid| {
        pgid = -pid;
        reporter.report(io, .proc_started) catch |err| log.err("Failed to report proc_started: {}", .{err});
    };
    errdefer self.reporters.cancel(self.io);
    // 启动监视器
    try monitor.start(io);
    // 启动上报器
    if (child.stdout) |f| try self.reporters.concurrent(io, Reporter.launch, .{ reporter, io, allocator, f, .out });
    if (child.stderr) |f| try self.reporters.concurrent(io, Reporter.launch, .{ reporter, io, allocator, f, .err });

    while (true) {
        const message = receiver.getOne(io) catch |err| {
            if (err != error.Canceled) log.err("Error receiving message: {s}", .{@errorName(err)});
            break;
        };
        switch (message) {
            .stop => if (!self.stopping.load(.monotonic)) {
                self.stopping.store(true, .monotonic);
                log.debug("Received stop message for {f}", .{reporter.proc_ref});
                _ = stop(io, &self.reporters, monitor, pgid);
                reporter.report(io, .proc_dead) catch |err| log.err("Failed to report proc_dead: {}", .{err}); // 发送死亡通知
                break;
            },
            .stop_sync => |done| {
                if (!self.stopping.load(.monotonic)) {
                    self.stopping.store(true, .monotonic);
                    log.debug("Received stop_sync message for {f}", .{reporter.proc_ref});
                    _ = stop(io, &self.reporters, monitor, pgid);
                    if (done.state.cmpxchgStrong(.pending, .done, .release, .monotonic) == null) {
                        done.reply(io); // 通知调用方
                    }
                    done.release(allocator); // 释放
                    reporter.report(io, .proc_dead) catch |err| log.err("Failed to report proc_dead: {}", .{err}); // 发送死亡通知
                    break;
                } else {
                    done.release(allocator); // 释放
                }
            },
            else => {},
        }
    }
}

const StopSignal = enum { none, term, pg_term };

fn stop(io: Io, other_tasks: *Io.Group, monitor: *Monitor, pgid: ?Pgid) StopSignal {
    var sent: StopSignal = .none; // 已发送的信号
    if (pgid) |id| {
        log.debug("Sending SIGTERM to pgid {d}", .{id});
        monitor.kill_source = .connector; // 信号源是连接器
        if (std.posix.kill(id, .TERM)) { // 发送 SIGTERM 给进程组
            sent = .pg_term;
        } else |err| { // 负数表示 pgid
            log.warn("Failed to send SIGTERM to pgid {d}: {s}", .{ id, @errorName(err) });
        }
    }
    if (sent == .none) { // 如果 pgid 信号未发送成功
        monitor.kill(io); // 发送终止信号，信号源是自身
        sent = .term;
    }
    // 注意：sent == .none 分支的 monitor.kill 会阻塞直到进程结束，但这个 .wait 仍然有收尾 future 的作用。
    monitor.wait(io); // 监视器会等待进程退出
    other_tasks.cancel(io); // 取消其它任务

    return sent;
}
