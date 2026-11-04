const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Supervisor = @import("Supervisor.zig");
const Argv = @import("Argv.zig");
const Proc = @import("Proc.zig");
const Recipe = @import("Recipe.zig");
const Control = @import("Control.zig");
const Done = @import("replies.zig").Done;
const errors = @import("errors.zig");
const SendError = errors.SendError;
const LaunchError = errors.LaunchError;
const Self = @This();

const log = std.log.scoped(.zsup_handle);

io: Io,
gpa: Allocator,
sup: *Supervisor,

pub fn sendCommand(self: *Self, command: Control.Command) SendError!void {
    while (self.sup.state.cmpxchgStrong(.working, .receiving, .acq_rel, .acquire)) |current| switch (current) {
        .starting => return SendError.Busy,
        .closing, .not_started => return SendError.NotWorking,
        .receiving => continue,
        .working => unreachable,
    };
    defer self.sup.state.store(.working, .monotonic);
    try self.sup.mailbox.putOneUncancelable(self.io, .{ .user = .{ .command = command } });
}

pub fn launch(self: *Self, argv: *const Argv, options: Recipe.Options) LaunchError!Proc.Ref {
    var recipe = try Recipe.init(self.gpa, argv, options);
    defer recipe.deinit(self.gpa);
    const done = try Done(Proc.Ref, LaunchError).create(self.gpa);
    defer done.release(self.gpa);
    done.retain(); // 即将发送出去，持有 +1
    self.sendCommand(.{ .start_proc = .{ .recipe = recipe, .done = done } }) catch |err| {
        done.release(self.gpa); // 发送失败，撤销
        return err;
    };
    done.event.waitUncancelable(self.io);
    if (done.err) |err| { // 如果 Supervisor 返回错误，直接返回
        return err;
    }

    return done.result orelse unreachable;
}

pub fn stopProc(self: *Self, ref: Proc.Ref) SendError!void {
    return self.sendCommand(.{ .stop_proc = .{ .ref = ref, .done = null } });
}

pub fn stopProcSync(self: *Self, ref: Proc.Ref, timeout: Io.Duration) errors.StopSyncError!void {
    log.debug("Sync stopping: {f}", .{ref});
    var done: *Done(void, errors.StopError) = try .create(self.gpa);
    defer done.release(self.gpa);
    done.retain(); // 即将发送出去，持有 +1
    self.sendCommand(.{ .stop_proc = .{ .ref = ref, .done = done } }) catch {
        done.release(self.gpa); // 发送失败，撤销
    };
    // 等待进程回应或超时
    done.event.waitTimeout(self.io, .{ .duration = .{ .clock = .awake, .raw = timeout } }) catch |err| {
        if (done.state.cmpxchgStrong(.pending, .timeout, .acq_rel, .acquire) == null) {
            return err; // 直接返回超时错误（reply 不会再调用）
        } else {
            try done.event.wait(self.io); // 进程已经回应，继续等待
        }
    };

    // 检查 done 中的错误
    if (done.err) |err| { // 虽然发送到了 Supervisor，但没有传递到 reply 侧
        if (err == errors.StopError.Closed or err == errors.StopError.ProcNotFound) done.release(self.gpa); // 撤销持有，因为 reply 侧没有收到消息
        return err;
    }

    return;
}

pub fn restartProc(self: *Self, ref: Proc.Ref) errors.RestartError!Proc.Ref {
    var recipe = try self.getProcRecipeOwned(ref);
    defer recipe.deinit(self.gpa);
    try self.stopProcSync(ref, .fromSeconds(3));
    return self.launch(&recipe.argv, recipe.options);
}

/// 获取指定进程的启动“配方”，调用者需自己释放。包含：
///  - Argv
///  - LaunchOptions
pub fn getProcRecipeOwned(self: *Self, ref: Proc.Ref) errors.GetRecipeError!Recipe {
    var done = try Done(Recipe, errors.GetRecipeError).create(self.gpa);
    defer done.release(self.gpa);
    done.retain(); // 即将发送出去，持有 +1
    self.sendCommand(.{ .get_recipe = .{ .ref = ref, .done = done } }) catch |err| {
        done.release(self.gpa); // 发送失败，撤销
        return err;
    };
    done.event.waitUncancelable(self.io);
    if (done.err) |err| {
        return err;
    }

    return done.result orelse unreachable;
}
