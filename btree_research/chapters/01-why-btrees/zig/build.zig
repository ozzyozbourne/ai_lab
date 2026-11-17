const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // One module: src/main.zig and everything it @imports.
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // expected_output.txt lives one directory up (shared with Rust). A module
    // cannot @embedFile outside its own directory, so expose it as an import.
    mod.addAnonymousImport("expected_output", .{ .root_source_file = b.path("../expected_output.txt") });

    const exe = b.addExecutable(.{ .name = "ch01_why_btrees", .root_module = mod });
    b.installArtifact(exe);

    // `zig build run`
    const run_step = b.step("run", "Print the chapter's fixed scenario");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    // `zig build test` (main.zig references every other file from a test block).
    const tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
