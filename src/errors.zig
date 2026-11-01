const std = @import("std");
const Proc = @import("Proc.zig");

pub const SendError = std.Io.QueueClosedError;
pub const ProcGetError = error{ProcNotFound};
pub const LaunchError = Proc.InitError || std.mem.Allocator.Error;
pub const StopError = ProcGetError || SendError;
pub const StopSyncError = StopError || std.mem.Allocator.Error || std.Io.Event.WaitTimeoutError;
pub const RestartError = StopSyncError || LaunchError;
