const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const mod = b.addModule("windows_app_bar", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const basic = b.addExecutable(.{
        .name = "windows_app_bar_basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic/main.zig"),
            .target = target,
        }),
    });
    basic.root_module.addImport("windows_app_bar", mod);

    const run_basic = b.addRunArtifact(basic);
    if (b.args) |args| {
        run_basic.addArgs(args);
    }
    const run_step = b.step("run", "Run the basic AppBar example");
    run_step.dependOn(&run_basic.step);
}
