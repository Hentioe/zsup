const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Recipe = @import("Recipe.zig");
const Proc = @import("Proc.zig");
const Control = @import("Control.zig");
const errors = @import("errors.zig");
const Self = @This();

// todo: 拥有 Argv
options: Recipe.Options = .{},
proc: *Proc,

pub fn init(allocator: Allocator, proc: Proc) Allocator.Error!Self {
    errdefer {
        var tmp = proc;
        tmp.deinit();
    }
    const proc_ptr = try allocator.create(Proc);
    proc_ptr.* = proc;
    return .{
        .proc = proc_ptr,
    };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.proc.deinit();
    allocator.destroy(self.proc);
    self.* = undefined;
}

pub fn send(self: *Self, io: Io, message: Control.Message) errors.SendError!void {
    return self.proc.receiver.putOneUncancelable(io, message);
}
