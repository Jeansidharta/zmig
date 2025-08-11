const builtin_migrations = @import("built-migrations");
const std = @import("std");
const sqlite = @import("sqlite");
const utils = @import("./utils.zig");

const Options = struct {
    checkHash: bool = false,
    checkName: bool = false,
};

/// This is here because the default implementation of sqlite.exec in the sqlite library
/// only executes one statement out of the query. Migrations usually have multiple statements,
/// so we need to use the raw c interface to use the function we want.
fn executeScript(db: *sqlite.Db, sql: []const u8, diags: *sqlite.Diagnostics) !void {
    const ret = sqlite.c.sqlite3_exec(db.db, sql.ptr, null, null, null);
    if (ret != sqlite.c.SQLITE_OK) {
        diags.err = db.getDetailedError();
        return sqlite.errorFromResultCode(ret);
    }
}

pub fn applyMigrations(db: *sqlite.Db, childAlloc: std.mem.Allocator, options: Options, diagnostics: ?*sqlite.Diagnostics) !void {
    var arenaAlloc = std.heap.ArenaAllocator.init(childAlloc);
    defer arenaAlloc.deinit();

    var dummyDiagnostics: sqlite.Diagnostics = .{};
    const diags = diagnostics orelse &dummyDiagnostics;

    try utils.createMigrationsTable(db, diags);

    var stmt = try db.prepareWithDiags(
        "select * from zmm_migrations ORDER BY timestamp ASC;",
        .{ .diags = diags },
    );
    defer stmt.deinit();

    var dbIter = try stmt.iterator(utils.DatabaseMigration, .{});

    var last_db_index: usize = 0;
    while (try dbIter.nextAlloc(arenaAlloc.allocator(), .{})) |_migration| {
        const db_migration: utils.DatabaseMigration = _migration;

        const file = if (last_db_index >= builtin_migrations.MIGRATIONS.len)
            return error.MissingMigrationFiles
        else
            builtin_migrations.MIGRATIONS[last_db_index];

        if (options.checkName and file.timestamp != db_migration.timestamp)
            return error.MigrationsTimestampDontMatch
        else if (options.checkName and !std.mem.eql(u8, file.name, db_migration.name))
            return error.MigrationsNameDontMatch
        else if (options.checkHash and file.up_hash != db_migration.up_md5)
            return error.MigrationsHashDontMatch;

        last_db_index += 1;
    }

    for (builtin_migrations.MIGRATIONS[last_db_index..]) |migration| {
        const query = migration.body;

        try db.exec("BEGIN TRANSACTION;", .{}, .{});
        try executeScript(db, query, diags);
        // try db.execDynamic(query, .{ .diags = diags }, .{});
        try utils.insertMigrationIntoTable(db, diags, .{
            .name = migration.name,
            .timestamp = migration.timestamp,
            .up_md5 = migration.up_hash,
            .down_md5 = 0,
        });
        try db.exec("COMMIT TRANSACTION;", .{}, .{});
    }
}
