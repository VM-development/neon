const std = @import("std");

const sqlite3_flags: []const []const u8 = &.{
    "-DSQLITE_THREADSAFE=1",
    "-DSQLITE_ENABLE_FTS5",
    "-DSQLITE_ENABLE_JSON1",
};

fn addSqlite3(mod: *std.Build.Module, b: *std.Build) void {
    mod.addCSourceFile(.{
        .file = b.path("src/sqlite3/sqlite3.c"),
        .flags = sqlite3_flags,
    });
    mod.addIncludePath(b.path("src/sqlite3"));
    mod.link_libc = true;
}

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
    // Bundle sqlite3 amalgamation — no system library required
    addSqlite3(lib_mod, b);

    // ── CLI executable ────────────────────────────────────────────────────────
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSqlite3(exe_mod, b);
    const exe = b.addExecutable(.{
        .name = "neon",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run neon");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSqlite3(test_mod, b);
    const lib_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
}
