const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // One module rooted at src/main.zig; tree.zig, demo.zig, tests.zig and
    // prng.zig are reached through @import from there.
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // expected_output.txt lives one directory up (shared with Rust). A module
    // cannot @embedFile outside its own directory, so expose it as an import.
    root.addAnonymousImport("expected_output", .{ .root_source_file = b.path("../expected_output.txt") });

    const exe = b.addExecutable(.{ .name = "ch17_key_compression_and_deduplication", .root_module = root });
    b.installArtifact(exe);

    const run_step = b.step("run", "Print the chapter's fixed scenario and measurements");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = root });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
