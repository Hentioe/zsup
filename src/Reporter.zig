const std = @import("std");
const Io = std.Io;
const Control = @import("Control.zig");
const Proc = @import("Proc.zig");
const StreamType = Control.StdStream.Type;
const Self = @This();

proc_ref: Proc.Ref,
control: *Control,

pub fn launch(self: *Self, io: Io, file: Io.File, st: StreamType) void {
    std.log.debug("Launching reporter ({s})", .{@tagName(st)});
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&chunk}) catch |err| {
            if (err != error.Canceled and err != error.EndOfStream) std.log.err("Error reading from stream: {s}", .{@errorName(err)});
            break;
        };
        self.report(io, .{ .stdout = .{ .st = st, .data = chunk[0..n] } });
    }
}

pub fn report(self: *Self, io: Io, message: Control.Message) void {
    self.control.send(io, self.proc_ref, message);
}
