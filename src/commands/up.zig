const std = @import("std");
const utils = @import("../utils.zig");
const MigrationDbRows = @import("../migration-db-rows.zig").MigrationDbRows;
const MigrationFiles = @import("../migration-files.zig").MigrationFiles;
const sqlite = @import("sqlite");

const Allocator = std.mem.Allocator;

/// Global variable that contains options specific to the `up` command.
pub var options = struct {
    numberOfMigrations: u32 = std.math.maxInt(u32),
    ignoreHashDifferences: bool = false,
}{};

pub fn run(
    alloc: Allocator,
    migrationsDirPath: []const u8,
    dbPath: [:0]const u8,
) !void {
    var stderr_writer = std.fs.File.stderr().writer(&.{});
    const stderr = &stderr_writer.interface;
    var stdout_writer = std.fs.File.stderr().writer(&.{});
    const stdout = &stdout_writer.interface;

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
        try stderr.print("Failed to open database file at {s}: {f}", .{ dbPath, diags });
        try stderr.flush();
        return e;
    };

    var files = try MigrationFiles.fromDir(alloc, migrationsDir, stderr);
    defer files.deinit();
    const rows = try MigrationDbRows.fromDbOldestFirst(alloc, &db, stderr);
    defer rows.deinit();

    try utils.checkMatchingMigrations(rows, files, stderr, options.ignoreHashDifferences);

    const remainingPairs = rem: {
        const arr = files.array.items[rows.migrations.len..];
        break :rem arr[0..@min(options.numberOfMigrations, arr.len)];
    };

    if (remainingPairs.len == 0) {
        try stdout.writeAll("No migrations to apply.\n");
        try stdout.flush();
        // TODO - this will leak the intermediaryArray's items
        return;
    }
    try stdout.print(
        "{} migration{s} to apply...\n",
        .{ remainingPairs.len, if (remainingPairs.len > 1) "s" else "" },
    );
    try stdout.flush();

    for (remainingPairs) |*pair| {
        try stdout.print("Applying migration {s}... ", .{pair.upFilename});
        try stdout.flush();
        try pair.execUp(alloc, &db, stderr);
        try stdout.print("Success\n", .{});
        try stdout.flush();
    }
}
