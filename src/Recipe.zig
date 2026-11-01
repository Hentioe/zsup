const Argv = @import("Argv.zig");

pub const Options = struct {
    stdout_redirected: bool = true,
    stderr_redirected: bool = true,
};

argv: *const Argv,
options: Options,
