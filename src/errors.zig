const std = @import("std");

pub const CustomError = error{
    ProcNotFound,
};

pub const SendError = error{ Canceled, Closed };

pub const Error =
    CustomError ||
    SendError ||
    std.mem.Allocator.Error ||
    std.process.SpawnError ||
    std.process.Child.WaitError ||
    std.Io.Event.WaitTimeoutError // Event.waitTimeout
;
