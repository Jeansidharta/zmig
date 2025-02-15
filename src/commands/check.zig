const std = @import("std");
const utils = @import("../utils.zig");
const MigrationDbRows = @import("../migration-db-rows.zig").MigrationDbRows;
const MigrationFiles = @import("../migration-files.zig").MigrationFiles;
const sqlite = @import("sqlite");

const Allocator = std.mem.Allocator;

/// Global variable that contains options specific to the `up` command.
pub var options = struct {}{};

pub fn run(
    alloc: Allocator,
    migrationsDirPath: []const u8,
    dbPath: [:0]const u8,
) !void {
    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();

    try stdout.print("Looking for migrations at \"./{s}\" directory...\n", .{migrationsDirPath});
    var migrationsDir = std.fs.cwd().openDir(migrationsDirPath, .{ .iterate = true }) catch |e| {
        try stderr.print(
            "Failed to open migrations directory at path \"{s}\": {}\n",
            .{ migrationsDirPath, e },
        );
        return e;
    };
    defer migrationsDir.close();

    var diags: sqlite.Diagnostics = .{};
    var db = sqlite.Db.init(.{
        .diags = &diags,
        .mode = .{ .File = dbPath },
        .open_flags = .{ .create = false, .write = false },
    }) catch |e| {
        if (e == error.SQLiteCantOpen) {
            try stderr.print("Could not open database file. Does it exist?\n", .{});
            return e;
        } else {
            try stderr.print("{s}\n", .{diags});
            return e;
        }
    };

    const tablesCount = try db.one(
        usize,
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='zmm_migrations';",
        .{},
        .{},
    );
    if (tablesCount.? != 1) {
        try stderr.print("Database does not have a migrations table setup yet\n", .{});
        return error.NoTableFound;
    }

    var files = try MigrationFiles.fromDir(alloc, migrationsDir, stderr);
    defer files.deinit();
    const rows = try MigrationDbRows.fromDbOldestFirst(alloc, &db, stderr);
    defer rows.deinit();

    try utils.checkMatchingMigrations(rows, files, stderr, false);

    const remainingPairs = files.array.items.len - rows.migrations.len;

    if (remainingPairs > 0) {
        try stdout.print(
            "{} migration{s} to apply...\n",
            .{ remainingPairs, if (remainingPairs > 1) "s" else "" },
        );
    }
}
