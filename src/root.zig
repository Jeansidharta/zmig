const migs = @import("built-migrations");
const std = @import("std");
const sqlite = @import("sqlite");
const utils = @import("./utils.zig");

pub fn applyMigrations(db: *sqlite.Db, diagnostics: ?*sqlite.Diagnostics) !void {
    const dummyDiagnostics: sqlite.Diagnostics = .{};
    const diags = diagnostics orelse &dummyDiagnostics;

    try utils.createMigrationsTable(db, diags);

    var stmt = try db.prepareWithDiags(
        "select * from zmm_migrations ORDER BY timestamp ASC;",
        .{ .diags = &diags },
    );
    defer stmt.deinit();

    const dbIter = try stmt.iterator(utils.DatabaseMigration, .{ .diags = diags });

    var lastDbIndex: usize = 0;
    while (try dbIter.next(.{})) |_migration| {
        const migration: utils.DatabaseMigration = _migration;

        const file = if (lastDbIndex >= migs.MIGRATIONS.len)
            return error.MissingMigrationFiles
        else
            migs.MIGRATIONS[lastDbIndex];

        if (file.timestamp != migration.timestamp)
            return error.MigrationsTimestampDontMatch
        else if (file.name != migration.name)
            return error.MigrationsNameDontMatch
        else if (file.hash != migration.up_md5)
            return error.MigrationsHashDontMatch;

        lastDbIndex += 1;
    }

    for (migs.MIGRATIONS) |migration| {
        const query = migration.body;

        try db.exec("BEGIN TRANSACTION;", .{}, .{});
        try db.execDynamic(query, .{ .diags = diags }, .{});
        utils.insertMigrationIntoTable(db, diags, migration);
        try db.exec("COMMIT TRANSACTION;", .{}, .{});
    }
}
