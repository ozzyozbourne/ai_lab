const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ch26_allocators_handles",
        .root_module = makeModule(b, target, optimize, .{}),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Print the chapter's fixed scenario");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    // The same tests, built three ways. Two allocators of the tour exist only under a
    // special build: BrkAllocator needs a single-threaded program, c_allocator needs libc.
    addTestStep(b, target, optimize, "test", "Run all tests (default build)", .{});
    addTestStep(b, target, optimize, "test-single-threaded", "Run all tests single-threaded (enables the BrkAllocator example)", .{ .single_threaded = true });
    addTestStep(b, target, optimize, "test-libc", "Run all tests linked against libc (enables the c_allocator example)", .{ .link_libc = true });
}

const Variant = struct { single_threaded: ?bool = null, link_libc: ?bool = null };

fn makeModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.OptimizeMode, variant: Variant) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = variant.single_threaded,
        .link_libc = variant.link_libc,
    });
    // expected_output.txt is shared with the Rust crate and lives one directory up; a
    // module cannot @embedFile outside its own directory, so expose it as an import.
    mod.addAnonymousImport("expected_output", .{ .root_source_file = b.path("../expected_output.txt") });
    return mod;
}

fn addTestStep(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.OptimizeMode, name: []const u8, description: []const u8, variant: Variant) void {
    const filters = b.option([]const []const u8, b.fmt("{s}-filter", .{name}), "Only run tests whose name contains this") orelse &.{};
    const tests = b.addTest(.{ .root_module = makeModule(b, target, optimize, variant), .filters = filters });
    b.step(name, description).dependOn(&b.addRunArtifact(tests).step);
}
