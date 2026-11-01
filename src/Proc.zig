const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Child = std.process.Child;
const Argv = @import("Argv.zig");
const Control = @import("Control.zig");
const Future = std.Io.Future;
const Monitor = @import("Monitor.zig");
const Reporter = @import("Reporter.zig");
const Self = @This();

pub const Ref = struct {
    pub const Value = std.atomic.Value(u32);
    pub var counter: Value = .init(0);

    pk: u32,
    pid: ?Child.Id = null,

    pub fn new() Ref {
        const pk = counter.fetchAdd(1, .monotonic);
        return .{ .pk = pk };
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
argv: Argv,
child: Child,
stopping: std.atomic.Value(bool),
control: Control,
connector: ?Future(ConnectError!void) = null,
group: Io.Group = .init,
monitor: ?Monitor = null,
reporter: ?Reporter = null,
receiver: Control.Message.Queue = .init(&.{}),

pub const InitError = std.process.SpawnError;

pub fn initOwned(io: Io, allocator: Allocator, control: Control, argv: Argv) InitError!Self {
    errdefer {
        var tmp = argv; // 复制一份，用于释放（内部的数据指针不变）。
        tmp.deinit(allocator);
    }
    const ref = Ref.new();
    const child = try std.process.spawn(io, .{
        .argv = argv.data.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });

    return .{
        .ref = ref,
        .child = child,
        .argv = argv,
        .io = io,
        .stopping = .init(false),
        .allocator = allocator,
        .control = control,
    };
}

pub fn deinit(self: *Self) void {
    // todo: 输出取消后的结果
    std.log.debug("Deinitializing: {f}", .{self.ref});
    if (self.connector) |*f| f.cancel(self.io) catch |err| std.log.warn("Connect cancel failed: {}", .{err});
    self.group.cancel(self.io); // 注意：要保证 connect 没有运行（避免同时调用 group.cancel）。
    self.argv.deinit(self.allocator);
    self.* = undefined;
}

pub fn link(self: *Self) Io.ConcurrentError!void {
    const io = self.io;
    if (self.connector != null) {
        std.log.warn("Already linked ({f})", .{self.ref});
        return;
    }
    self.reporter = .{ .proc_ref = self.ref, .control = &self.control };
    self.monitor = .{ .proc_ref = self.ref, .control = &self.control };
    self.connector = try io.concurrent(connect, .{self});
}

const Pgid = std.posix.pid_t;
const ConnectError = std.Io.ConcurrentError;

pub fn connect(self: *Self) ConnectError!void {
    // 正常情况，进入 receiver 消息处理后，不应该返回错误。
    // 如果返回了错误，表示在前置阶段就失败了。进程可能进入“失控”状态。上报为 proc_lost（丢失连接）
    errdefer self.control.send(self.io, self.ref, .proc_lost) catch |err| std.log.err("Failed to send lost message: {}", .{err});

    const io = self.io;
    const allocator = self.allocator;
    const child = &self.child;
    const reporter = &self.reporter.?;
    const monitor = &self.monitor.?;
    const receiver = &self.receiver;

    var pgid: ?Pgid = null;
    if (builtin.os.tag != .windows) if (child.id) |pid| {
        self.ref.pid = pid;
        pgid = -pid;
        reporter.report(io, .proc_started) catch |err| std.log.err("Failed to report proc_started: {}", .{err});
    };
    errdefer self.group.cancel(self.io);
    // 启动监视器
    try self.group.concurrent(io, Monitor.launch, .{ monitor, io, child });
    // 启动上报器
    if (child.stdout) |f| try self.group.concurrent(io, Reporter.launch, .{ reporter, io, allocator, f, .out });
    if (child.stderr) |f| try self.group.concurrent(io, Reporter.launch, .{ reporter, io, allocator, f, .err });

    while (true) {
        const message = receiver.getOne(io) catch |err| {
            if (err != error.Canceled) std.log.err("Error receiving message: {s}", .{@errorName(err)});
            break;
        };
        switch (message) {
            .stop => if (!self.stopping.load(.monotonic)) {
                self.stopping.store(true, .monotonic);
                std.log.debug("Received stop message for {f}", .{reporter.proc_ref});
                _ = stop(io, &self.group, child, pgid);
                reporter.report(io, .proc_dead) catch |err| std.log.err("Failed to report proc_dead: {}", .{err}); // 发送死亡通知
                break;
            },
            .stop_sync => |done| if (!self.stopping.load(.monotonic)) {
                self.stopping.store(true, .monotonic);
                std.log.debug("Received stop_sync message for {f}", .{reporter.proc_ref});
                _ = stop(io, &self.group, child, pgid);
                if (done.state.cmpxchgStrong(.pending, .done, .release, .monotonic) == null) {
                    done.reply(io); // 通知调用方
                } else {
                    // 调用方已返回，直接销毁 done 结构体
                    done.destroy(self.allocator);
                }
                reporter.report(io, .proc_dead) catch |err| std.log.err("Failed to report proc_dead: {}", .{err}); // 发送死亡通知
                break;
            },
            else => {},
        }
    }
}

const StopSignal = enum { none, term, pg_term };

fn stop(io: Io, group: *Io.Group, child: *Child, pgid: ?Pgid) StopSignal {
    var sent: StopSignal = .none; // 已发送的信号
    if (pgid) |id| {
        std.log.debug("Sending SIGTERM to pgid {d}", .{id});
        if (std.posix.kill(id, .TERM)) { // 发送 SIGTERM 给进程组
            sent = .pg_term;
        } else |err| { // 负数表示 pgid
            std.log.warn("Failed to send SIGTERM to pgid {d}: {s}", .{ id, @errorName(err) });
        }
    }
    if (sent == .none) { // 如果 pgid 信号未发送成功
        child.kill(io);
        sent = .term;
    } // 无需手动 wait，因为 group 中的 monitor 任务在调用它
    group.cancel(io); // 取消监视器、上报器任务

    return sent;
}
