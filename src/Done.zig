const std = @import("std");
const atomic = std.atomic;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Self = @This();

const State = enum(u8) { pending, done, timeout };

refs: atomic.Value(u32) = .init(1),
state: atomic.Value(State) = .init(.pending),
event: Io.Event = .unset,

pub fn create(allocator: Allocator) error{OutOfMemory}!*Self {
    const ptr = try allocator.create(Self);
    ptr.* = .{};
    return ptr;
}

fn destroy(self: *Self, allocator: Allocator) void {
    allocator.destroy(self);
}

pub fn retain(self: *Self) void {
    _ = self.refs.fetchAdd(1, .monotonic);
}

pub fn release(self: *Self, allocator: Allocator) void {
    if (self.refs.fetchSub(1, .acq_rel) == 1) self.destroy(allocator);
}

pub fn reply(self: *Self, io: Io) void {
    self.event.set(io);
}
