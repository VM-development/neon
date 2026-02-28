const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Public library module ─────────────────────────────────────────────────
    // Downstream projects (e.g. aeon) import neon via:
    //   .neon = .{ .path = "../neon" }    in build.zig.zon
    //   neon_dep.module("neon")           in build.zig
    const lib_mod = b.addModule("neon", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.linkSystemLibrary("sqlite3", .{});
    lib_mod.link_libc = true;

    // ── CLI executable ────────────────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "neon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.linkLibC();
    exe.linkSystemLibrary("sqlite3");
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run neon");
    run_step.dependOn(&run_cmd.step);

    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lib_tests.linkLibC();
    lib_tests.linkSystemLibrary("sqlite3");

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
}
