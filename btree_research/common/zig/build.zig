const std = @import("std");

/// `zig build test` runs every test in common/zig.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // golden.txt lives one directory up (shared with Rust). A module cannot
    // @embedFile outside its own directory, so expose it as an import.
    mod.addAnonymousImport("golden", .{ .root_source_file = b.path("../golden.txt") });

    const tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
