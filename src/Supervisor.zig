const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Proc = @import("Proc.zig");
const Done = @import("Done.zig");
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

    pub fn stop(self: *Managed, io: Io) Error!void {
        if (!self.proc.stopping.load(.monotonic)) return self.send(io, .stop) // 仅在进程未执行过时发送停止消息
        else std.log.warn("Proc is already stopping: {f}", .{self.proc.ref});
    }

    pub fn send(self: *Managed, io: Io, message: Control.Message) Error!void {
        return self.proc.receiver.putOne(io, message);
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
    std.log.debug("Deinitializing supervisor", .{});
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
    std.log.debug("Supervisor exited", .{});
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
                std.log.debug("All procs exited, supervisor exiting", .{});
                return .exit;
            }
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

pub fn launch(self: *Self, argv: Proc.Argv, options: LaunchOptions) Error!Proc.Ref {
    const control: Control = .{ .queue = &self.mailbox };
    const proc = try Proc.init(self.io, self.gpa, control, argv);
    var managed: Managed = try .create(self.gpa, proc);
    managed.launch_options = options;
    try self.procs.put(proc.ref.pk, managed);

    managed.proc.link();

    return proc.ref;
}

pub fn stopProc(self: *Self, ref: Proc.Ref) Error!void {
    if (self.procs.getPtr(ref.pk)) |managed| {
        try managed.stop(self.io);
        return;
    }

    return Error.ProcNotFound;
}

pub fn stopProcSync(self: *Self, ref: Proc.Ref, timeout: Io.Duration) Error!void {
    if (timeout.toSeconds() < 1) std.log.warn("Timeout is too short: {d} seconds", .{timeout.toSeconds()});
    if (self.procs.getPtr(ref.pk)) |managed| {
        std.log.debug("Sync stopping: {f}", .{ref});
        var done: *Done = try .create(self.gpa);
        defer if (!done.timeout.load(.monotonic)) done.destroy(self.gpa); // 没有超时，释放 done
        try managed.send(self.io, .{ .stop_sync = done });
        // 等待进程停止或超时
        done.event.waitTimeout(self.io, .{ .duration = .{ .clock = .awake, .raw = timeout } }) catch |err| {
            std.log.warn("Timeout waiting for {f}", .{ref});
            done.timeout.store(true, .monotonic); // 标记为超时，让回复侧自己释放
            return err;
        };

        return;
    }

    return Error.ProcNotFound;
}

pub fn restartProc(self: *Self, ref: Proc.Ref) Error!Proc.Ref {
    if (self.procs.get(ref.pk)) |managed| {
        try self.stopProcSync(ref, .fromSeconds(3));
        const argv = managed.proc.argv;
        const options = managed.launch_options;
        return self.launch(argv, options);
    }

    return Error.ProcNotFound;
}

pub fn waitAll(self: *Self) Error!void {
    if (self.listened) |*f| {
        std.log.debug("Sending wait all command to supervisor", .{});
        self.mailbox.putOne(self.io, .{ .user = .{ .command = .wait_all } }) catch unreachable;
        f.await(self.io);
        self.listened = null; // 避免 shutdown 发消息
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
