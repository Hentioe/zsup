const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Supervisor = @import("Supervisor.zig");
const Argv = @import("Argv.zig");
const Proc = @import("Proc.zig");
const Recipe = @import("Recipe.zig");
const Managed = @import("Managed.zig");
const Control = @import("Control.zig");
const replies = @import("replies.zig");
const errors = @import("errors.zig");
const SendError = errors.SendError;
const LaunchError = errors.LaunchError;
const Self = @This();

const log = std.log.scoped(.handle);

io: Io,
gpa: Allocator,
sup: *Supervisor,

pub fn sendCommand(self: *Self, command: Control.Command) SendError!void {
    switch (self.sup.state.load(.monotonic)) {
        .starting => return SendError.Busy,
        .closing, .not_started => return SendError.NotWorking,
        .working => {},
    }
    try self.sup.mailbox.putOneUncancelable(self.io, .{ .user = .{ .command = command } });
}

pub fn launch(self: *Self, argv: *const Argv, options: Recipe.Options) LaunchError!Proc.Ref {
    const cloned_argv = try Argv.clone(self.gpa, argv);
    var recipe = Recipe.init(cloned_argv, options);
    defer recipe.deinit(self.gpa); // cloned_argv 的释放交给 recipe
    const control: Control = .{ .queue = &self.sup.mailbox };
    const proc = try Proc.init(self.io, self.gpa, control, recipe.argv.data.items);
    // 注意：proc 初始化到 managed 接管之间，不要有错误返回（否则会导致 proc 泄漏）。
    var managed = try Managed.init(self.gpa, &recipe, proc);
    errdefer managed.deinit(self.gpa); // proc 的释放交给 managed
    const done = try replies.Done(void, LaunchError).create(self.gpa);
    defer done.release(self.gpa);
    done.retain(); // 即将发送出去，持有 +1
    self.sendCommand(.{ .proc_created = .{ .managed = managed, .done = done } }) catch |err| {
        done.release(self.gpa); // 发送失败，撤销
        return err;
    };
    done.event.waitUncancelable(self.io);
    if (done.err) |err| { // 如果 Supervisor 返回错误，直接返回
        return err;
    }

    return proc.ref;
}

pub fn stopProc(self: *Self, ref: Proc.Ref) SendError!void {
    return self.sendCommand(.{ .stop_proc = .{ .ref = ref, .done = null } });
}

pub fn stopProcSync(self: *Self, ref: Proc.Ref, timeout: Io.Duration) errors.StopSyncError!void {
    log.debug("Sync stopping: {f}", .{ref});
    var done: *replies.Done(void, errors.StopError) = try .create(self.gpa);
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
    var done = try replies.Done(Recipe, errors.GetRecipeError).create(self.gpa);
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
