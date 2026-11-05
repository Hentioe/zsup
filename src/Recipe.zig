const std = @import("std");
const Allocator = std.mem.Allocator;
const Child = std.process.Child;
const Argv = @import("Argv.zig");
const Self = @This();

pub const Cwd = union(enum) {
    inherit,
    path: []u8,

    pub fn deinit(self: Cwd, allocator: Allocator) void {
        switch (self) {
            .path => |s| allocator.free(s),
            else => {},
        }
    }

    pub fn allocPath(allocator: Allocator, path: []const u8) Allocator.Error!Cwd {
        return Cwd{ .path = try allocator.dupe(u8, path) };
    }

    pub fn clone(self: *const Cwd, allocator: Allocator) Allocator.Error!Cwd {
        return switch (self.*) {
            .inherit => .inherit,
            .path => |p| Cwd{ .path = try allocator.dupe(u8, p) },
        };
    }

    pub fn toChildCwd(self: *const Cwd) Child.Cwd {
        return switch (self.*) {
            .inherit => .inherit,
            .path => |p| .{ .path = p },
        };
    }
};

pub const Options = struct {
    stdout_redirected: bool = true,
    stderr_redirected: bool = true,
    cwd: Cwd = .inherit,

    pub fn deinit(self: *Options, allocator: Allocator) void {
        self.cwd.deinit(allocator);
    }

    pub fn clone(self: *const Options, allocator: Allocator) Allocator.Error!Options {
        var cwd = try self.cwd.clone(allocator);
        errdefer cwd.deinit(allocator);
        return Options{
            .stdout_redirected = self.stdout_redirected,
            .stderr_redirected = self.stderr_redirected,
            .cwd = cwd,
        };
    }
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
    var argv = try Argv.clone(allocator, &self.argv);
    errdefer argv.deinit(allocator);
    const options = try self.options.clone(allocator);
    errdefer options.deinit(allocator);
    return .{
        .argv = argv,
        .options = options,
    };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.argv.deinit(allocator);
    self.options.deinit(allocator);
    self.* = undefined;
}
