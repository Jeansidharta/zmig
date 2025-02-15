const std = @import("std");
const Import = std.Build.Module.Import;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });
    const zigcli = b.dependency("zig-cli", .{
        .target = target,
        .optimize = optimize,
    });
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            Import{ .module = sqlite.module("sqlite"), .name = "sqlite" },
        },
    });
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            Import{ .module = sqlite.module("sqlite"), .name = "sqlite" },
            Import{ .module = zigcli.module("zig-cli"), .name = "zig-cli" },
            Import{ .module = lib_mod, .name = "migration_lib" },
        },
    });
    const lib = b.addStaticLibrary(.{
        .name = "zmig",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);
    const exe = b.addExecutable(.{
        .name = "zmig",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);

    const checkStep = b.step("check", "Make sure it compiles");
    checkStep.dependOn(&exe.step);
}
