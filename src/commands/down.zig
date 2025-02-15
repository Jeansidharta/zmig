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
    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();

    try stdout.print("Looking for migrations at \"./{s}\" directory...\n", .{migrationsDirPath});
    var migrationsDir = std.fs.cwd().makeOpenPath(migrationsDirPath, .{ .iterate = true }) catch |e| {
        try stderr.print(
            "Failed to create migrations directory at path \"{s}\": {}\n",
            .{ migrationsDirPath, e },
        );
        return e;
    };
    defer migrationsDir.close();

    var db = try utils.openOrCreateDatabase(dbPath);

    const rows = try MigrationDbRows.fromDbNewestFirst(alloc, &db, stderr);
    defer rows.deinit();

    if (rows.migrations.len == 0) {
        try stdout.print("No down migrations to run.\n", .{});
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
