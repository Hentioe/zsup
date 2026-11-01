const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Self = @This();

const State = enum(u8) { pending, done, timeout };

event: Io.Event = .unset,
state: std.atomic.Value(State) = .init(.pending),

pub fn create(allocator: Allocator) error{OutOfMemory}!*Self {
    const ptr = try allocator.create(Self);
    ptr.* = .{};
    return ptr;
}

pub fn destroy(self: *Self, allocator: Allocator) void {
    allocator.destroy(self);
}

pub fn reply(self: *Self, io: Io) void {
    self.event.set(io);
}
