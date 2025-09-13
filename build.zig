const std = @import("std");

/// This will invoke the `build/make-migrations-file.zig` script over all
/// of the provided migrations, and return a LazyPath to a zig source
/// file containing the result.
fn makeMigrationsFile(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) std.Build.LazyPath {
    const generate_step = b.addRunArtifact(
        b.addExecutable(.{
            .name = "migration-generator",
            // Enabled due to https://github.com/vrischmann/zig-sqlite/issues/195
            .use_llvm = true,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("./build/make-migrations-file.zig"),
                .imports = &.{
                    .{
                        // Allows the migrations build module to access our utils functions
                        .name = "utils",
                        .module = b.createModule(.{
                            .root_source_file = b.path("src/utils.zig"),
                            .target = target,
                            .optimize = optimize,
                        }),
                    },
                },
            }),
        }),
    );

    // Having a named WriteFiles step allows us to easily access
    // it later from upper modules (modules that import this one)
    const write_files_step = b.addNamedWriteFiles("clone_migrations");

    generate_step.addDirectoryArg(write_files_step.getDirectory());
    return generate_step.addOutputFileArg("migrations.zig");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });
    const zigcli = b.dependency("cli", .{
        .target = target,
        .optimize = optimize,
    });
    _ = b.addModule("zmig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .module = sqlite.module("sqlite"), .name = "sqlite" },
            .{ .module = b.createModule(.{
                .root_source_file = makeMigrationsFile(b, target, optimize),
                .target = target,
                .optimize = optimize,
            }), .name = "built-migrations" },
        },
    });
    const exe_mod = b.addModule("zmig-cli", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .module = sqlite.module("sqlite"), .name = "sqlite" },
            .{ .module = zigcli.module("cli"), .name = "cli" },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zmig",
        .root_module = exe_mod,
        // Enabled due to https://github.com/vrischmann/zig-sqlite/issues/195
        .use_llvm = true,
    });
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("zmig", "Invokes the zmig tool");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    const checkStep = b.step("check", "Make sure it compiles");
    checkStep.dependOn(&exe.step);
}
