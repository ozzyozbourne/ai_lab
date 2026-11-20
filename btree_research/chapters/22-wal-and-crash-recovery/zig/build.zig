const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `zig build test -Dlong=true` adds a longer crash loop (120 puts instead
    // of 40). `zig build run` never depends on it: its output is fixed.
    const long = b.option(bool, "long", "Also run the long crash loop in the tests") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "long", long);

    // One module: src/main.zig imports every other file directly.
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", options);
    // expected_output.txt lives one directory up (shared with Rust). A module
    // cannot @embedFile outside its own directory, so expose it as an import.
    mod.addAnonymousImport("expected_output", .{ .root_source_file = b.path("../expected_output.txt") });

    const exe = b.addExecutable(.{ .name = "ch22_wal_and_crash_recovery", .root_module = mod });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the chapter program");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    const filters = b.option([]const []const u8, "test-filter", "Only run tests whose name contains this") orelse &.{};
    const tests = b.addTest(.{ .root_module = mod, .filters = filters });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
