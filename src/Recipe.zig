const std = @import("std");
const Allocator = std.mem.Allocator;
const Argv = @import("Argv.zig");
const Self = @This();

pub const Options = struct {
    stdout_redirected: bool = true,
    stderr_redirected: bool = true,
};

argv: Argv,
options: Options,

pub fn init(allocator: Allocator, argv: *const Argv, options: Options) Allocator.Error!Self {
    const owned_argv = try Argv.clone(allocator, argv);
    return .{
        .argv = owned_argv,
        .options = options,
    };
}

pub fn clone(self: *const Self, allocator: Allocator) Allocator.Error!Self {
    const argv = try Argv.clone(allocator, &self.argv);
    return .{
        .argv = argv,
        .options = self.options,
    };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.argv.deinit(allocator);
    self.* = undefined;
}
