const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });

    const zmig = b.dependency("zmig", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("sqlite", sqlite.module("sqlite"));

    const exe = b.addExecutable(.{
        .name = "simple",
        .root_module = exe_mod,
    });

    // zmig related things
    {
        // Installation step 2
        exe_mod.addImport("zmig", zmig.module("zmig"));

        // Installation step 3: Make sure the migrations tool can see the new migrations
        {
            const migrations_dir = b.path("migrations");
            const clone_migrations_step = zmig.builder.named_writefiles.get("clone_migrations").?;
            _ = clone_migrations_step.addCopyDirectory(migrations_dir, "", .{ .include_extensions = &.{".sql"} });
        }

        // Installation step 4: Export the zmig cli
        {
            const zmig_cli = b.addRunArtifact(
                b.addExecutable(.{
                    .root_module = zmig.module("zmig-cli"),
                    .name = "zmig-cli",
                }),
            );
            const run_zmig_cli = b.step("zmig", "Invokes the zmig-cli tool");
            run_zmig_cli.dependOn(&zmig_cli.step);
            zmig_cli.addArgs(b.args orelse &.{});
        }
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
