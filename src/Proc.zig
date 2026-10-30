const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Child = std.process.Child;
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
    pid: ?i32 = null,

    pub fn new() Ref {
        return .{ .pk = counter.fetchAdd(1, .monotonic) };
    }

    pub fn format(self: *const Ref, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.pid) |pid| {
            try writer.print("pk={d},pid={d}", .{ self.pk, pid });
        } else {
            try writer.print("pk={d}", .{self.pk});
        }
    }
};
pub const Argv = []const []const u8;

io: Io,
ref: Ref,
argv: Argv,
child: Child,
control: Control,
linked: ?Future(void) = null,
monitor: ?Monitor = null,
reporter: ?Reporter = null,
receiver: Control.Message.Queue = .init(&.{}),

pub fn init(io: Io, control: Control, argv: Argv) Error!Self {
    const ref = Ref.new();
    const child = try std.process.spawn(io, .{
        // todo: 从外部传入参数
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    return .{
        .ref = ref,
        .child = child,
        .argv = argv,
        .io = io,
        .control = control,
    };
}

pub fn deinit(self: *Self) void {
    // todo: 输出取消后的结果
    std.log.debug("Deinitializing: {f}", .{self.ref});
    if (self.linked) |*f| f.cancel(self.io);
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
    self.linked = io.async(connect, .{ io, &self.child, &self.monitor.?, &self.receiver, &self.reporter.? });
}

pub fn connect(
    io: Io,
    child: *Child,
    monitor: *Monitor,
    receiver: *Control.Message.Queue,
    reporter: *Reporter,
) void {
    if (builtin.os.tag != .windows) if (child.id) |pid| {
        reporter.report(io, .{ .proc_started = pid });
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
            .stop => {
                std.log.debug("Received stop message for {f}", .{reporter.proc_ref});
                group.cancel(io);
                child.kill(io);
                reporter.report(io, .proc_dead); // 发送死亡通知
                break;
            },
            else => {},
        }
    }
}
