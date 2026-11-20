const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module: src/root.zig and everything it imports (the B-link tree).
    const mod = b.addModule("ch20_blink_trees", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Executable: src/main.zig, the demo program whose stdout is
    // ../expected_output.txt.
    const exe = b.addExecutable(.{
        .name = "ch20_blink_trees",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ch20_blink_trees", .module = mod },
            },
        }),
    });
    // expected_output.txt lives one directory up (shared with Rust). A module
    // cannot @embedFile outside its own directory, so expose it as an import.
    exe.root_module.addAnonymousImport("expected_output", .{ .root_source_file = b.path("../expected_output.txt") });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the demo program");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    // `zig build test --summary all` runs the tests of both modules.
    const filters = b.option([]const []const u8, "test-filter", "Only run tests whose name contains this") orelse &.{};
    const mod_tests = b.addTest(.{ .root_module = mod, .filters = filters });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module, .filters = filters });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
