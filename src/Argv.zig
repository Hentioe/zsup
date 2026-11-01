const std = @import("std");
const Allocator = std.mem.Allocator;
const Self = @This();

pub const Error = Allocator.Error;

data: std.ArrayListUnmanaged([]const u8),

pub fn init(allocator: Allocator, program: []const u8) Error!Self {
    var self: Self = .{
        .data = try .initCapacity(allocator, 1),
    };
    try self.data.append(allocator, program);
    return self;
}

/// 从另一个 `Argv` 实例，克隆一个副本。
pub fn cloneFrom(allocator: Allocator, other: *const Self) Error!Self {
    var self: Self = .{
        .data = try .initCapacity(allocator, other.data.items.len),
    };
    try self.data.appendSlice(allocator, other.data.items);
    return self;
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.data.deinit(allocator);
}

pub fn addArg(self: *Self, allocator: Allocator, arg: []const u8) Error!void {
    try self.data.append(allocator, arg);
}

pub fn addArgs(self: *Self, allocator: Allocator, more: []const []const u8) Error!void {
    try self.data.appendSlice(allocator, more);
}

pub fn getProgram(self: *const Self) []const u8 {
    return self.data.items[0];
}

pub fn getArgs(self: *const Self) []const []const u8 {
    return self.data.items[1..];
}
