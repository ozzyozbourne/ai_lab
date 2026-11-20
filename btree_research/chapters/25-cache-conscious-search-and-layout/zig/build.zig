const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // One module: src/main.zig and the files it imports.
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // expected_output.txt is shared with the Rust twin and lives one directory
    // up. A module cannot @embedFile outside its own directory, so the build
    // script exposes the file as an import named "expected_output".
    mod.addAnonymousImport("expected_output", .{ .root_source_file = b.path("../expected_output.txt") });

    const exe = b.addExecutable(.{ .name = "ch25_cache_conscious_search_and_layout", .root_module = mod });
    b.installArtifact(exe);

    // `zig build run` prints the fixed scenario; `zig build run -- --bench`
    // also prints an optional micro-benchmark to stderr.
    const run_step = b.step("run", "Run the fixed scenario");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    const filters = b.option([]const []const u8, "test-filter", "Only run tests whose name contains this") orelse &.{};
    const tests = b.addTest(.{ .root_module = mod, .filters = filters });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
