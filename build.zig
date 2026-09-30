const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("windows_app_bar", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
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
            .optimize = optimize,
        }),
    });
    basic.root_module.addImport("windows_app_bar", mod);

    const run_example_basic = b.addRunArtifact(basic);
    if (b.args) |args| {
        run_example_basic.addArgs(args);
    }
    const run_example_basic_step = b.step("example-basic", "Run the basic AppBar example");
    run_example_basic_step.dependOn(&run_example_basic.step);
}
