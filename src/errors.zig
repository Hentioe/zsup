const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Proc = @import("Proc.zig");

pub const StartError = error{ Busy, AlreadyStarted } || Io.ConcurrentError;
pub const SendError = error{ Busy, NotWorking } || Io.QueueClosedError;
pub const GetProcError = error{ProcNotFound};
pub const LaunchError = error{LinkFailed} || SendError || Proc.InitError || Allocator.Error || Io.ConcurrentError;
pub const StopError = GetProcError || SendError;
pub const StopSyncError = StopError || Allocator.Error || Io.Event.WaitTimeoutError;
pub const GetRecipeError = SendError || GetProcError || Allocator.Error;
pub const RestartError = GetRecipeError || StopSyncError || LaunchError;
