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
    var stderr_writer = std.fs.File.stderr().writer(&.{});
    const stderr = &stderr_writer.interface;
    var stdout_writer = std.fs.File.stderr().writer(&.{});
    const stdout = &stdout_writer.interface;

    var diags: sqlite.Diagnostics = .{};
    var db = sqlite.Db.init(.{
        .diags = &diags,
        .mode = .{ .File = dbPath },
        .open_flags = .{ .create = false, .write = false },
    }) catch |e| {
        if (e == error.SQLiteCantOpen) {
            try stderr.print("Could not open database file. Does it exist?\n", .{});
            try stderr.flush();
            return e;
        } else {
            try stderr.print("{f}\n", .{diags});
            try stderr.flush();
            return e;
        }
    };

    const tablesCount = try db.one(
        usize,
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='zmig_migrations';",
        .{},
        .{},
    );
    if (tablesCount.? != 1) {
        try stderr.print("Database does not have a migrations table setup yet\n", .{});
        try stderr.flush();
        return error.NoTableFound;
    }

    try stdout.print("Looking for migrations at \"{s}\" directory...\n", .{migrationsDirPath});
    try stdout.flush();
    var migrationsDir = std.fs.cwd().openDir(migrationsDirPath, .{ .iterate = true }) catch |e| {
        try stderr.print(
            "Failed to open migrations directory at path \"{s}\": {}\n",
            .{ migrationsDirPath, e },
        );
        try stderr.flush();
        return e;
    };
    defer migrationsDir.close();

    var files = try MigrationFiles.fromDir(alloc, migrationsDir, stderr);
    defer files.deinit();
    const rows = try MigrationDbRows.fromDbOldestFirst(alloc, &db, stderr);
    defer rows.deinit();

    try utils.checkMatchingMigrations(rows, files, stderr, false);

    const remainingPairs = files.array.items.len - rows.migrations.len;

    if (remainingPairs > 0)
        try stdout.print(
            "{} migration{s} to apply...\n",
            .{ remainingPairs, if (remainingPairs > 1) "s" else "" },
        )
    else
        try stdout.print("No migrations to apply\n", .{});
    try stdout.flush();

    try stdout.print("Everything is Ok!\n", .{});
    try stdout.flush();
}
