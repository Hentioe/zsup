const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Proc = @import("Proc.zig");
const Control = @import("Control.zig");
const Error = @import("errors.zig").Error;
const Self = @This();

const Managed = struct {
    launch_options: LaunchOptions = .{},
    proc: *Proc,

    pub fn create(allocator: Allocator, proc: Proc) Error!Managed {
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
};

const LaunchOptions = struct {
    stdout_redirected: bool = true,
    stderr_redirected: bool = true,
};

io: Io,
gpa: Allocator,
procs: std.AutoHashMap(u32, Managed),
mailbox: Control.Mail.Queue = .init(&.{}),
listened: ?Io.Future(void) = null,
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
    if (!self.exited) self.shutdown();
    var iter = self.procs.valueIterator();
    while (iter.next()) |m| m.destroy(self.gpa);
    self.procs.deinit();
    self.* = undefined;
}

pub fn start(self: *Self) void {
    if (self.listened != null) return;
    self.listened = self.io.async(listen, .{self});
}

pub const HandleStatus = enum { normal, exit };

pub fn listen(self: *Self) void {
    while (true) {
        const mail = self.mailbox.getOne(self.io) catch |err| {
            switch (err) {
                error.Canceled => break,
                else => unreachable,
            }
        };
        var status: HandleStatus = .normal;
        if (std.meta.activeTag(mail) == .proc) status = self.handleProcMessage(mail.proc);
        if (std.meta.activeTag(mail) == .user) status = self.handleUserCommand(mail.user);

        switch (status) {
            .exit => break,
            .normal => {},
        }
    }
    std.log.debug("Supervisor exiting", .{});
}

pub fn handleProcMessage(self: *Self, mail: Control.ProcMail) HandleStatus {
    switch (mail.message) {
        .stdout => |bytes| {
            if (self.procs.getPtr(mail.ref.pk)) |m| if (m.launch_options.stdout_redirected) {
                Io.File.stdout().writeStreamingAll(self.io, bytes.data) catch unreachable;
            };
        },
        .stderr => |bytes| {
            if (self.procs.getPtr(mail.ref.pk)) |m| if (m.launch_options.stderr_redirected) {
                Io.File.stderr().writeStreamingAll(self.io, bytes.data) catch unreachable;
            };
        },
        .proc_started => |pid| {
            if (self.procs.getPtr(mail.ref.pk)) |m| {
                m.proc.ref.pid = pid;
                std.log.info("Started: {f}", .{m.proc.ref});
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
                std.log.info("All procs exited, supervisor exiting", .{});
                return .exit;
            }
        },
        else => {},
    }

    return .normal;
}

pub fn handleUserCommand(_: *Self, mail: Control.UserMail) HandleStatus {
    switch (mail.command) {
        .shutdown => {
            return .exit;
        },
        else => {},
    }

    return .normal;
}

pub fn launch(self: *Self, argv: Proc.Argv, options: LaunchOptions) Error!Proc.Ref {
    const control: Control = .{ .queue = &self.mailbox };
    const proc = try Proc.init(self.io, control, argv);
    var managed: Managed = try .create(self.gpa, proc);
    managed.launch_options = options;
    try self.procs.put(proc.ref.pk, managed);

    managed.proc.link();

    return proc.ref;
}

pub fn stopProc(self: *Self, ref: Proc.Ref) Error!void {
    if (self.procs.getPtr(ref.pk)) |m| {
        std.log.info("Stopping: {f}", .{ref});
        try m.proc.receiver.putOne(self.io, .stop);
        return;
    }

    return Error.ProcNotFound;
}

pub fn waitAll(self: *Self) Error!void {
    if (self.listened) |*f| {
        self.waiting = true;
        f.await(self.io);
        self.listened = null; // 避免 shutdown 发消息
    }
}

pub fn shutdown(self: *Self) void {
    if (self.exited) return;
    var iter = self.procs.valueIterator();
    while (iter.next()) |m| {
        // todo: 改成预构造的一次性批量消息
        m.proc.receiver.putOne(self.io, .stop) catch |err| {
            switch (err) {
                error.Canceled => {},
                else => unreachable,
            }
        };
    }
    if (self.listened) |*f| {
        std.log.info("Sending shutdown command to supervisor", .{});
        self.mailbox.putOne(self.io, .{ .user = .{ .command = .shutdown } }) catch unreachable;
        f.await(self.io); // todo: 处理取消的返回值
        self.listened = null; // 避免 wait 发消息
    }
    self.exited = true;
    std.log.info("Supervisor shutdown complete", .{});
}
