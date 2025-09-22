const builtin_migrations = @import("built-migrations");
const std = @import("std");
const sqlite = @import("sqlite");
const utils = @import("./utils.zig");

pub const Diagnostics = struct {
    kind: union(enum) {
        Unknown,
        SqliteError: sqlite.Diagnostics,
        MissingMigration,
        TimestampMismatch,
        NameMismatch,
        HashMismatch,

        pub fn format(self: @This(), writer: *std.Io.Writer) !void {
            switch (self) {
                .Unknown => {
                    try writer.writeAll("unknown Error");
                },
                .SqliteError => |diags| {
                    try writer.print("{f}", .{diags});
                },
                .MissingMigration => {
                    try writer.writeAll("missing migration files");
                },
                .TimestampMismatch => {
                    try writer.writeAll("timestamp mismatch");
                },
                .HashMismatch => {
                    try writer.writeAll("hash mismatch");
                },
                .NameMismatch => {
                    try writer.writeAll("name mismatch");
                },
            }
        }
    } = .Unknown,

    stage: union(enum) {
        CreatingMigrationTable,
        FetchingMigrationsFromTable,
        VerifyingMigrations: usize,
        ApplyingMigrations: usize,

        pub fn format(self: @This(), writer: *std.Io.Writer) !void {
            try writer.writeAll("While ");
            switch (self) {
                .CreatingMigrationTable => {
                    try writer.print("creating migrations table", .{});
                },
                .FetchingMigrationsFromTable => {
                    try writer.print("fetching migrations from table", .{});
                },
                .VerifyingMigrations => |migration_index| {
                    if (migration_index >= builtin_migrations.MIGRATIONS.len) {
                        try writer.writeAll("The local database has more migrations than available files");
                    } else {
                        const migration = builtin_migrations.MIGRATIONS[migration_index];
                        try writer.print("verifying migration {d}-{s}", .{ migration.timestamp, migration.name });
                    }
                },
                .ApplyingMigrations => |migration_index| {
                    const migration = builtin_migrations.MIGRATIONS[migration_index];
                    try writer.print("applying migration {d}-{s}", .{ migration.timestamp, migration.name });
                },
            }
        }
    } = .CreatingMigrationTable,

    const empty: @This() = .{};

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        try writer.print("Error {f}: {f}", .{ self.stage, self.kind });
    }
};

const Options = struct {
    checkHash: bool = false,
    checkName: bool = false,
    diagnostics: ?*Diagnostics = null,

    pub const default: @This() = .{};
};

pub fn applyMigrations(db: *sqlite.Db, alloc: std.mem.Allocator, options: Options) !void {
    var arenaAlloc = std.heap.ArenaAllocator.init(alloc);
    defer arenaAlloc.deinit();

    var sqliteDiags: sqlite.Diagnostics = .{};
    var dummyDiags: Diagnostics = .empty;
    const diags = options.diagnostics orelse &dummyDiags;
    diags.* = .empty;

    diags.stage = .CreatingMigrationTable;
    utils.createMigrationsTable(db, &sqliteDiags) catch |e| {
        diags.kind = .{ .SqliteError = sqliteDiags };
        return e;
    };

    diags.stage = .FetchingMigrationsFromTable;
    var stmt = db.prepareWithDiags(
        "select * from zmig_migrations ORDER BY timestamp ASC;",
        .{ .diags = &sqliteDiags },
    ) catch |e| {
        diags.kind = .{ .SqliteError = sqliteDiags };
        return e;
    };
    defer stmt.deinit();

    var dbIter = try stmt.iterator(utils.DatabaseMigration, .{});

    var last_db_index: usize = 0;
    while (try dbIter.nextAlloc(arenaAlloc.allocator(), .{})) |_migration| : (last_db_index += 1) {
        diags.stage = .{ .VerifyingMigrations = last_db_index };
        const db_migration: utils.DatabaseMigration = _migration;

        const file = if (last_db_index >= builtin_migrations.MIGRATIONS.len) {
            diags.kind = .MissingMigration;
            return error.MissingMigrationFiles;
        } else builtin_migrations.MIGRATIONS[last_db_index];

        if (options.checkName and file.timestamp != db_migration.timestamp) {
            diags.kind = .TimestampMismatch;
            return error.MigrationsTimestampDontMatch;
        } else if (options.checkName and !std.mem.eql(u8, file.name, db_migration.name)) {
            diags.kind = .NameMismatch;
            return error.MigrationsNameDontMatch;
        } else if (options.checkHash and file.up_hash != @as(u128, @bitCast(db_migration.up_md5.data[0..16].*))) {
            diags.kind = .HashMismatch;
            return error.MigrationsHashDontMatch;
        }
    }

    for (builtin_migrations.MIGRATIONS[last_db_index..], 0..) |migration, index| {
        diags.stage = .{ .ApplyingMigrations = index };
        const query = migration.body;

        db.exec("BEGIN TRANSACTION;", .{}, .{}) catch |e| {
            diags.kind = .{ .SqliteError = sqliteDiags };
            return e;
        };
        db.execMulti(query, .{ .diags = &sqliteDiags }) catch |e| {
            if (e != error.EmptyQuery) {
                diags.kind = .{ .SqliteError = sqliteDiags };
                return e;
            }
        };
        utils.insertMigrationIntoTable(db, &sqliteDiags, .{
            .name = migration.name,
            .timestamp = migration.timestamp,
            .up_md5 = .{ .data = &@as([16]u8, @bitCast(migration.up_hash)) },
            .down_md5 = .{ .data = &@as([16]u8, @bitCast(@as(u128, 0))) },
        }) catch |e| {
            diags.kind = .{ .SqliteError = sqliteDiags };
            return e;
        };
        db.exec("COMMIT TRANSACTION;", .{}, .{}) catch |e| {
            diags.kind = .{ .SqliteError = sqliteDiags };
            return e;
        };
    }
}
