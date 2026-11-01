const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Control = @import("Control.zig");
const Proc = @import("Proc.zig");
const StdStream = Control.StdStream;
const errors = @import("errors.zig");
const Self = @This();

proc_ref: Proc.Ref,
control: *Control,

pub fn launch(self: *Self, io: Io, allocator: Allocator, file: Io.File, st: StdStream.Type) void {
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&chunk}) catch |err| {
            if (err != error.Canceled and err != error.EndOfStream) std.log.err("Error reading from stream: {s}", .{@errorName(err)});
            break;
        };
        const bytes = StdStream.Bytes.create(allocator, st, chunk[0..n]) catch |err| {
            std.log.err("Failed to initialize bytes: {}", .{err});
            if (err == Allocator.Error.OutOfMemory) {
                // 日志打印丢失了 n 个字节的数据
                std.log.err("Out of memory, lost {d} bytes of {s}", .{ n, @tagName(st) });
                continue; // 如果是内存问题，继续读取
            } else {
                break; // 跳出循环，结束。todo: 考虑上报发生的错误，但目前只有内存问题。
            }
        };
        var message: Control.Message = undefined;
        switch (st) {
            .err => message = .{ .stderr = bytes },
            .out => message = .{ .stdout = bytes },
        }
        self.report(io, message) catch |err| {
            std.log.err("Failed to report stream data: {}", .{err});
            bytes.destroy(allocator);
            break;
        };
    }
}

pub fn report(self: *Self, io: Io, message: Control.Message) errors.SendError!void {
    return self.control.send(io, self.proc_ref, message);
}
