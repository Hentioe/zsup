const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Recipe = @import("Recipe.zig");
const Proc = @import("Proc.zig");
const Control = @import("Control.zig");
const errors = @import("errors.zig");
const Self = @This();

recipe: Recipe,
proc: *Proc,

/// 初始化 Managed 实例。此函数会接管 `proc` 的释放，而 `recipe` 仍由外部管理，内部深克隆后由 Managed 拥有自己的副本。
pub fn init(allocator: Allocator, recipe: *const Recipe, proc: *Proc) Allocator.Error!Self {
    errdefer proc.destroy();
    const owned_recipe = try recipe.clone(allocator);
    return .{
        .recipe = owned_recipe,
        .proc = proc,
    };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.proc.destroy();
    allocator.destroy(self.proc);
    self.recipe.deinit(allocator);
    self.* = undefined;
}

pub fn isStdoutRedirected(self: *const Self) bool {
    return self.recipe.options.stdout_redirected;
}

pub fn isStderrRedirected(self: *const Self) bool {
    return self.recipe.options.stderr_redirected;
}

pub fn send(self: *Self, io: Io, message: Control.Message) errors.SendError!void {
    return self.proc.receiver.putOneUncancelable(io, message);
}
