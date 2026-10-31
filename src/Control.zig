const std = @import("std");
const Io = std.Io;
const Proc = @import("Proc.zig");
const Self = @This();

pub const StdStream = struct {
    pub const Type = enum { out, err };
    pub const Bytes = struct { st: Type, data: []const u8 };
};

pub const Message = union(enum) {
    stdout: StdStream.Bytes,
    stderr: StdStream.Bytes,
    stop, // 停止进程
    proc_started: i32, // 进程已启动
    proc_dead, // 进程已死亡

    pub const Queue = Io.Queue(Message);
};

pub const Command = enum {
    stop_proc,
    wait_all,
};

pub const ProcMail = struct {
    ref: Proc.Ref,
    message: Message,
};

pub const UserMail = struct {
    command: Command,
};

pub const Mail = union(enum) {
    proc: ProcMail,
    user: UserMail,

    pub const Queue = Io.Queue(Mail);
};

queue: *Mail.Queue,

// todo: 返回错误
pub fn send(self: *Self, io: Io, proc_ref: Proc.Ref, message: Message) void {
    self.queue.putOne(io, .{ .proc = .{ .ref = proc_ref, .message = message } }) catch unreachable;
}
