const std = @import("std");
const sqlite = @import("sqlite");

const Allocator = std.mem.Allocator;
const digest_length = std.crypto.hash.Md5.digest_length;
pub const HashInt = std.meta.Int(.unsigned, digest_length * 8);

const MigrationDbRows = @import("./migration-db-rows.zig").MigrationDbRows;
const MigrationFiles = @import("./migration-files.zig").MigrationFiles;

const ParseFileNameError = error{
    MissingTimestamp,
    MissingName,
    InvalidTimestamp,
    InvalidExtension,
};

const ParsedFileName = struct {
    name: []const u8,
    timestamp: u64,
    typ: enum { up, down },
};

pub const DatabaseMigration = struct {
    name: []const u8,
    timestamp: u64,
    up_md5: sqlite.Blob,
    down_md5: sqlite.Blob,
};

fn splitFileName(filename: []const u8) ParseFileNameError!struct { []const u8, []const u8, []const u8 } {
    var timestampIter = std.mem.splitScalar(u8, filename, '-');
    const timestamp = timestampIter.next() orelse return error.MissingTimestamp;
    var nameIter = std.mem.splitScalar(u8, timestampIter.rest(), '.');
    const name = nameIter.next() orelse return error.MissingName;
    const extension = nameIter.rest();
    return .{ timestamp, name, extension };
}

pub fn parseFileName(filename: []const u8) ParseFileNameError!ParsedFileName {
    const timestampStr, const name, const extension = try splitFileName(filename);
    const timestamp = std.fmt.parseInt(u64, timestampStr, 10) catch return error.InvalidTimestamp;
    const typ: @FieldType(ParsedFileName, "typ") =
        if (std.mem.eql(u8, extension, "up.sql"))
            .up
        else if (std.mem.eql(u8, extension, "down.sql"))
            .down
        else
            return error.InvalidExtension;
    return .{
        .name = name,
        .timestamp = timestamp,
        .typ = typ,
    };
}

pub fn hashBuf(
    buf: []const u8,
) HashInt {
    var md5: [digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(buf, &md5, .{});
    return @bitCast(md5);
}

pub fn expectHashBuf(
    buf: []const u8,
    hash: HashInt,
) bool {
    return hashBuf(buf) == hash;
}

pub fn expectHashFile(
    migrationsDir: std.fs.Dir,
    path: []const u8,
    hash: HashInt,
    alloc: Allocator,
) !bool {
    const contents = try migrationsDir.readFileAlloc(path, alloc, @enumFromInt(1024 * 1024 * 256));
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
        // Skip the timestamp section of the entry name
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

pub fn createMigrationsTable(db: *sqlite.Db, diags: ?*sqlite.Diagnostics) !void {
    return db.exec(
        \\ CREATE TABLE IF NOT EXISTS zmm_migrations (
        \\   name TEXT NOT NULL,
        \\   timestamp INTEGER PRIMARY KEY ASC NOT NULL,
        \\   up_md5 BLOB NOT NULL,
        \\   down_md5 BLOB NOT NULL
        \\ ) STRICT;
    , .{ .diags = diags }, .{});
}

pub fn insertMigrationIntoTable(
    db: *sqlite.Db,
    diags: ?*sqlite.Diagnostics,
    migration: DatabaseMigration,
) !void {
    return db.exec(
        \\ INSERT INTO zmm_migrations (
        \\   name,
        \\   timestamp,
        \\   up_md5,
        \\   down_md5
        \\ ) VALUES (?, ?, ?, ?);
    , .{ .diags = diags }, .{
        migration.name,
        migration.timestamp,
        migration.up_md5,
        migration.down_md5,
    });
}

pub fn openOrCreateDatabase(databasePath: [:0]const u8, diags: ?*sqlite.Diagnostics) !sqlite.Db {
    var db = try sqlite.Db.init(.{
        .diags = diags,
        .mode = .{ .File = databasePath },
        .open_flags = .{
            .create = true,
            .write = true,
        },
    });

    try createMigrationsTable(&db, diags);

    return db;
}

pub fn checkMatchingMigrations(
    rows: MigrationDbRows,
    files: MigrationFiles,
    stderr: *std.Io.Writer,
    ignoreHashes: bool,
) !void {
    const migrationsDir = files.dir;
    for (rows.migrations, 0..) |dbRow, index| {
        if (index >= files.array.items.len) {
            try stderr.print(
                "Files for previously applied migration \"{d}-{s}\" were not found\n",
                .{ dbRow.timestamp, dbRow.name },
            );
            try stderr.flush();
            return error.MissingMigration;
        }
        const file = files.array.items[index];
        if (!file.eqlNameAndTimestamp(dbRow)) {
            try stderr.print(
                "Files for previously applied migration \"{d}-{s}\" were not found\n",
                .{ dbRow.timestamp, dbRow.name },
            );
            try stderr.flush();
            return error.NonMatchingMigrations;
        }
        if (ignoreHashes) continue;
        if (!try expectHashFile(migrationsDir, file.upFilename, dbRow.up_md5, files.alloc)) {
            try stderr.print(
                "Migration \"{s}\" was modified since it was last applied\n",
                .{file.upFilename},
            );
            try stderr.flush();
            return error.NonMatchingMigrations;
        }
        if (!try expectHashFile(migrationsDir, file.downFilename, dbRow.down_md5, files.alloc)) {
            try stderr.print(
                "Migration \"{s}\" was modified since its up counterpart was applied\n",
                .{file.name},
            );
            try stderr.flush();
            return error.NonMatchingMigrations;
        }
    }
}
