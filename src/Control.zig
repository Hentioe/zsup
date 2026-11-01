const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Proc = @import("Proc.zig");
const replies = @import("replies.zig");
const Done = replies.Done;
const Recipe = @import("Recipe.zig");
const errors = @import("errors.zig");
const Self = @This();

pub const StdStream = struct {
    pub const Type = enum { out, err };
    pub const Bytes = struct {
        st: Type,
        data: []u8,

        pub fn create(allocator: Allocator, st: Type, data: []const u8) Allocator.Error!*Bytes {
            const owned = try allocator.alloc(u8, data.len);
            @memcpy(owned, data);
            errdefer allocator.free(owned);
            const ptr = try allocator.create(Bytes);

            ptr.* = .{
                .st = st,
                .data = owned,
            };

            return ptr;
        }

        pub fn destroy(self: *Bytes, allocator: Allocator) void {
            allocator.free(self.data);
            allocator.destroy(self);
        }
    };
};

pub const Message = union(enum) {
    stdout: *StdStream.Bytes,
    stderr: *StdStream.Bytes,
    stop, // 请求停止进程
    stop_sync: *Done(void, errors.StopError),
    proc_started, // 进程已启动
    proc_dead, // 进程已死亡
    proc_lost, // 进程丢失连接

    pub const Queue = Io.Queue(Message);
};

pub const Command = union(enum) {
    stop_proc: struct { ref: Proc.Ref, done: ?*Done(void, errors.StopError) },
    get_recipe: struct { ref: Proc.Ref, done: *Done(Recipe, errors.ProcGetError) },
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

pub fn send(self: *Self, io: Io, proc_ref: Proc.Ref, message: Message) errors.SendError!void {
    try self.queue.putOneUncancelable(io, .{ .proc = .{ .ref = proc_ref, .message = message } });
}
