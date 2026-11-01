const std = @import("std");
const atomic = std.atomic;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const DoneState = enum(u8) { pending, done, timeout };

pub fn Done(comptime E: type) type {
    if (@typeInfo(E) != .error_set) @compileError("E must be an error set, got " ++ @typeName(E));

    return struct {
        const Self = @This();

        refs: atomic.Value(u32) = .init(1),
        state: atomic.Value(DoneState) = .init(.pending),
        err: ?E = null,
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

        pub fn replyErr(self: *Self, io: Io, err: E) void {
            self.err = err;
            self.event.set(io);
        }
    };
}
