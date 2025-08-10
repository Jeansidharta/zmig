const std = @import("std");
const Import = std.Build.Module.Import;

fn makeMigrationsFile(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) std.Build.LazyPath {
    const migrationsGenerator_mod = b.addModule("migrations-maker", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("./build/make-migrations-file.zig"),
    });
    // Allows the migrations build module to access our utils functions
    migrationsGenerator_mod.addAnonymousImport(
        "utils",
        .{
            .root_source_file = b.path("src/utils.zig"),
            .target = target,
            .optimize = optimize,
        },
    );
    const migrationsGenerator = b.addExecutable(.{
        .name = "migration-generator",
        .root_module = migrationsGenerator_mod,
    });
    const generateMigrationsStep = b.addRunArtifact(migrationsGenerator);
    const outMigStep = b.step("migrations", "generate migrations zig file");
    outMigStep.dependOn(&generateMigrationsStep.step);

    const write_files_step = b.addNamedWriteFiles("clone_migrations");
    generateMigrationsStep.addDirectoryArg(write_files_step.getDirectory());
    return generateMigrationsStep.addOutputFileArg("migrations.zig");
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
    const migrationsFile = makeMigrationsFile(b, target, optimize);
    _ = b.addModule("zmig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            Import{ .module = sqlite.module("sqlite"), .name = "sqlite" },
            Import{ .module = b.createModule(.{
                .root_source_file = migrationsFile,
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
            Import{ .module = sqlite.module("sqlite"), .name = "sqlite" },
            Import{ .module = zigcli.module("cli"), .name = "cli" },
        },
    });

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
