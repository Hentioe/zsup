const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("sup", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const examples = [_][]const u8{
        "basic",
        "crash",
        "spawn",
        "restart",
        "ctrl_c_shutdown",
    };
    for (examples) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zsup", .module = mod }},
            }),
        });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        const step = b.step(
            b.fmt("run-{s}", .{name}),
            b.fmt("Run the {s} example", .{name}),
        );
        step.dependOn(&run.step);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
