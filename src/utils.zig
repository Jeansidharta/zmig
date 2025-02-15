const std = @import("std");
const sqlite = @import("sqlite");

const Allocator = std.mem.Allocator;
const digest_length = std.crypto.hash.Md5.digest_length;

const MigrationDbRows = @import("./migration-db-rows.zig").MigrationDbRows;
const MigrationFiles = @import("./migration-files.zig").MigrationFiles;

pub fn expectHashBuf(
    buf: []const u8,
    hash: []const u8,
) bool {
    if (hash.len < digest_length) @panic("MD5 hash has incorrect digest length");

    var md5: [digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(buf, &md5, .{});
    return std.mem.eql(u8, &md5, hash);
}

pub fn expectHashFile(
    migrationsDir: std.fs.Dir,
    path: []const u8,
    hash: []const u8,
    alloc: Allocator,
) !bool {
    const contents = try migrationsDir.readFileAlloc(alloc, path, 1024 * 1024 * 256);
    defer alloc.free(contents);
    return expectHashBuf(contents, hash);
}

/// Scans the migrations directory for the given name. Note that a name should not inlcude the
/// timestamp or the file extension. If the name is, for example, "migration_name", this
/// function will look for <TIMESTAMP>-migration_name.<up|down>.sql
pub fn hasMigrationWithName(
    migrationDir: std.fs.Dir,
    name: []const u8,
) !bool {
    var iter = migrationDir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;

        var entryNameIter = std.mem.splitAny(u8, entry.name, "-.");
        // Skip the timestamp section of the entryy name
        _ = entryNameIter.next();
        const entryNameOpt = entryNameIter.next();
        if (entryNameOpt == null) {
            continue;
        }
        const entryName = entryNameOpt.?;
        if (std.mem.eql(u8, entryName, name)) return true;
    }
    return false;
}

pub fn openOrCreateDatabase(databasePath: [:0]const u8) !sqlite.Db {
    const stderr = std.io.getStdErr().writer();
    var diags: sqlite.Diagnostics = .{};
    var db = sqlite.Db.init(.{
        .diags = &diags,
        .mode = .{ .File = databasePath },
        .open_flags = .{
            .create = true,
            .write = true,
        },
    }) catch |e| {
        try stderr.print("{any}\n", .{diags});
        return e;
    };

    db.exec(
        \\ CREATE TABLE IF NOT EXISTS zmm_migrations (
        \\   name TEXT NOT NULL,
        \\   timestamp INTEGER PRIMARY KEY ASC NOT NULL,
        \\   up_md5 TEXT NOT NULL,
        \\   down_md5 TEXT NOT NULL
        \\ ) STRICT;
    , .{ .diags = &diags }, .{}) catch |e| {
        try stderr.print("{any}\n", .{diags});
        return e;
    };

    return db;
}

pub fn checkMatchingMigrations(
    rows: MigrationDbRows,
    files: MigrationFiles,
    stderr: anytype,
    ignoreHashes: bool,
) !void {
    const migrationsDir = files.dir;
    for (rows.migrations, 0..) |dbRow, index| {
        if (index >= files.array.items.len) {
            try stderr.print(
                "Files for previously applied migration \"{d}-{s}\" were not found\n",
                .{ dbRow.timestamp, dbRow.name },
            );
        }
        const file = files.array.items[index];
        if (!file.eqlNameAndTimestamp(dbRow)) {
            try stderr.print(
                "Files for previously applied migration \"{d}-{s}\" were not found\n",
                .{ dbRow.timestamp, dbRow.name },
            );
            return error.NonMatchingMigrations;
        }
        if (ignoreHashes) continue;
        if (!try expectHashFile(migrationsDir, file.upFilename, &dbRow.up_md5, files.alloc)) {
            try stderr.print(
                "Migration \"{s}\" was modified since it was last applied\n",
                .{file.upFilename},
            );
            return error.NonMatchingMigrations;
        }
        if (!try expectHashFile(migrationsDir, file.downFilename, &dbRow.down_md5, files.alloc)) {
            try stderr.print(
                "Migration \"{s}\" was modified since its up counterpart was applied\n",
                .{file.name},
            );
            return error.NonMatchingMigrations;
        }
    }
}
