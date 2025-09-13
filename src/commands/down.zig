const std = @import("std");
const utils = @import("../utils.zig");
const MigrationDbRows = @import("../migration-db-rows.zig").MigrationDbRows;
const MigrationFiles = @import("../migration-files.zig").MigrationFiles;
const sqlite = @import("sqlite");

const Allocator = std.mem.Allocator;

/// Global variable that contains options specific to the `up` command.
pub var options = struct {
    numberOfMigrations: u32 = 1,
    ignoreHashDifferences: bool = false,
}{};

pub fn run(
    alloc: Allocator,
    migrationsDirPath: []const u8,
    dbPath: [:0]const u8,
) !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    var stderr_writer = std.fs.File.stderr().writer(&.{});
    const stderr = &stderr_writer.interface;

    try stdout.print("Looking for migrations at \"./{s}\" directory...\n", .{migrationsDirPath});
    try stdout.flush();
    var migrationsDir = std.fs.cwd().makeOpenPath(migrationsDirPath, .{ .iterate = true }) catch |e| {
        try stderr.print(
            "Failed to create migrations directory at path \"{s}\": {}\n",
            .{ migrationsDirPath, e },
        );
        try stderr.flush();
        return e;
    };
    defer migrationsDir.close();

    var diags: sqlite.Diagnostics = .{};
    var db = utils.openOrCreateDatabase(dbPath, &diags) catch |e| {
        try stderr.print("{f}", .{diags});
        try stderr.flush();
        return e;
    };

    const rows = try MigrationDbRows.fromDbNewestFirst(alloc, &db, stderr);
    defer rows.deinit();

    if (rows.migrations.len == 0) {
        try stdout.print("No down migrations to run.\n", .{});
        try stdout.flush();
        return;
    }
    const numberOfMigrations = @min(options.numberOfMigrations, rows.migrations.len);

    for (rows.migrations[0..numberOfMigrations]) |dbRow| {
        try dbRow.execDown(
            alloc,
            migrationsDir,
            &db,
            options.ignoreHashDifferences,
            stdout,
            stderr,
        );
    }
}
