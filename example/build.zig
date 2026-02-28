const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Resolve the neon path dependency and import its public module.
    const neon_dep = b.dependency("neon", .{
        .target = target,
        .optimize = optimize,
    });
    const neon_mod = neon_dep.module("neon");

    const exe = b.addExecutable(.{
        .name = "neon_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Import neon — sqlite3 + libc are already linked by the neon module itself.
    exe.root_module.addImport("neon", neon_mod);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Build and run the example");
    run_step.dependOn(&run_cmd.step);
}
