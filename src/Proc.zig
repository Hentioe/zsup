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
const Error = @import("errors.zig").Error;
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
linked: ?Future(void) = null,
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
    if (self.linked) |*f| f.cancel(self.io);
    self.argv.deinit(self.allocator);
    self.* = undefined;
}

pub fn link(self: *Self) void {
    const io = self.io;
    if (self.linked != null) {
        std.log.warn("Already linked ({f})", .{self.ref});
        return;
    }
    self.reporter = .{ .proc_ref = self.ref, .control = &self.control };
    self.monitor = .{ .proc_ref = self.ref, .control = &self.control };
    self.linked = io.async(connect, .{self});
}

const Pgid = std.posix.pid_t;

pub fn connect(self: *Self) void {
    const io = self.io;
    const child = &self.child;
    const reporter = &self.reporter.?;
    const monitor = &self.monitor.?;
    const receiver = &self.receiver;

    var pgid: ?Pgid = null;
    if (builtin.os.tag != .windows) if (child.id) |pid| {
        pgid = -pid;
        reporter.report(io, .{ .proc_started = pid }) catch |err| std.log.err("Failed to report proc_started: {}", .{err});
    };
    var group: Io.Group = .init;
    // 启动监视器
    group.async(io, Monitor.launch, .{ monitor, io, child });
    // 启动上报器
    if (child.stdout) |f| group.async(io, Reporter.launch, .{ reporter, io, f, .out });
    if (child.stderr) |f| group.async(io, Reporter.launch, .{ reporter, io, f, .err });

    while (true) {
        const message = receiver.getOne(io) catch |err| {
            if (err != error.Canceled) std.log.err("Error receiving message: {s}", .{@errorName(err)});
            break;
        };
        switch (message) {
            .stop => if (!self.stopping.load(.monotonic)) {
                self.stopping.store(true, .monotonic);
                std.log.debug("Received stop message for {f}", .{reporter.proc_ref});
                _ = stop(io, &group, child, pgid);
                reporter.report(io, .proc_dead) catch |err| std.log.err("Failed to report proc_dead: {}", .{err}); // 发送死亡通知
                break;
            },
            .stop_sync => |done| if (!self.stopping.load(.monotonic)) {
                self.stopping.store(true, .monotonic);
                std.log.debug("Received stop_sync message for {f}", .{reporter.proc_ref});
                _ = stop(io, &group, child, pgid);
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
