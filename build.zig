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
    // Bundle sqlite3 amalgamation — no system library required
    lib_mod.addCSourceFile(.{
        .file = b.path("src/sqlite3/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_ENABLE_JSON1",
        },
    });
    lib_mod.addIncludePath(b.path("src/sqlite3"));
    lib_mod.link_libc = true;

    // ── CLI executable ────────────────────────────────────────────────────────
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addCSourceFile(.{
        .file = b.path("src/sqlite3/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_ENABLE_JSON1",
        },
    });
    exe_mod.addIncludePath(b.path("src/sqlite3"));
    exe_mod.link_libc = true;
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

    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lib_tests.root_module.addCSourceFile(.{
        .file = b.path("src/sqlite3/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_ENABLE_JSON1",
        },
    });
    lib_tests.root_module.addIncludePath(b.path("src/sqlite3"));
    lib_tests.root_module.link_libc = true;

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
}
