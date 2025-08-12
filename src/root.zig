const builtin_migrations = @import("built-migrations");
const std = @import("std");
const sqlite = @import("sqlite");
const utils = @import("./utils.zig");

const Options = struct {
    checkHash: bool = false,
    checkName: bool = false,
};

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
        else if (options.checkHash and file.up_hash != @as(u128, @bitCast(db_migration.up_md5.data[0..16].*)))
            return error.MigrationsHashDontMatch;

        last_db_index += 1;
    }

    for (builtin_migrations.MIGRATIONS[last_db_index..]) |migration| {
        const query = migration.body;

        try db.exec("BEGIN TRANSACTION;", .{}, .{});
        db.execMulti(query, .{ .diags = diags }) catch |e| {
            if (e != error.EmptyQuery) return e;
        };
        try utils.insertMigrationIntoTable(db, diags, .{
            .name = migration.name,
            .timestamp = migration.timestamp,
            .up_md5 = .{ .data = &@as([16]u8, @bitCast(migration.up_hash)) },
            .down_md5 = .{ .data = &@as([16]u8, @bitCast(@as(u128, 0))) },
        });
        try db.exec("COMMIT TANSACTION;", .{}, .{});
    }
}
