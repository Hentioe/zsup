const std = @import("std");
const Allocator = std.mem.Allocator;
const Self = @This();

data: std.ArrayListUnmanaged([]const u8),

pub fn init(allocator: Allocator, program: []const u8) Allocator.Error!Self {
    var self: Self = .{
        .data = try .initCapacity(allocator, 1),
    };
    errdefer self.deinit(allocator);
    const owned = try allocator.dupe(u8, program);
    errdefer allocator.free(owned);
    try self.data.append(allocator, owned);
    return self;
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    for (self.data.items) |item| {
        allocator.free(item);
    }
    self.data.deinit(allocator);
}

/// 从另一个 `Argv` 实例，深克隆一个副本。
pub fn clone(allocator: Allocator, other: *const Self) Allocator.Error!Self {
    return cloneFromData(allocator, other.data.items);
}

pub fn cloneFromData(allocator: Allocator, data: []const []const u8) Allocator.Error!Self {
    var self: Self = .{
        .data = try .initCapacity(allocator, data.len),
    };
    errdefer self.deinit(allocator);
    for (data) |item| {
        const owned = try allocator.dupe(u8, item);
        errdefer allocator.free(owned);
        try self.data.append(allocator, owned);
    }
    return self;
}

pub fn addArg(self: *Self, allocator: Allocator, arg: []const u8) Allocator.Error!void {
    const owned = try allocator.dupe(u8, arg);
    errdefer allocator.free(owned);
    try self.data.append(allocator, owned);
}

pub fn addArgs(self: *Self, allocator: Allocator, more: []const []const u8) Allocator.Error!void {
    for (more) |item| {
        const owned = try allocator.dupe(u8, item);
        errdefer allocator.free(owned);
        try self.data.append(allocator, owned);
    }
}

pub fn getProgram(self: *const Self) []const u8 {
    return self.data.items[0];
}

pub fn getArgs(self: *const Self) []const []const u8 {
    return self.data.items[1..];
}
