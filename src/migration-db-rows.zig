const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const utils = @import("utils.zig");
const digest_length = std.crypto.hash.Md5.digest_length;

pub const DbRow = struct {
    name: []const u8,
    timestamp: u64,
    up_md5: utils.HashInt,
    down_md5: utils.HashInt,

    pub fn execDown(
        self: @This(),
        alloc: Allocator,
        migrationsDir: std.fs.Dir,
        db: *sqlite.Db,
        ignoreHash: bool,
        stdout: anytype,
        stderr: anytype,
    ) !void {
        const downFilename = try std.fmt.allocPrint(
            alloc,
            "{d}-{s}.down.sql",
            .{ self.timestamp, self.name },
        );
        defer alloc.free(downFilename);

        const downMigration = try migrationsDir.readFileAlloc(
            alloc,
            downFilename,
            256 * 1024 * 1024,
        );
        defer alloc.free(downMigration);

        if (!ignoreHash) {
            if (!utils.expectHashBuf(downMigration, self.down_md5)) {
                try stderr.print(
                    \\Migration {s} was modified after its up counterpart was executed.
                    \\If you wish to continue anyway, add the --ignore-hash-differences flag
                ,
                    .{downFilename},
                );
            }
        }

        try stdout.print(
            "Applying migration \"{s}\"...",
            .{downFilename},
        );

        try db.exec("BEGIN TRANSACTION;", .{}, .{});

        var diags: sqlite.Diagnostics = .{};
        db.execDynamic(downMigration, .{ .diags = &diags }, .{}) catch |e| {
            if (e == error.EmptyQuery) {
                try stderr.print("\nWarning: migration \"{s}\" has an empty query\n", .{downFilename});
            } else {
                try stderr.print("\n{s}\n", .{diags});
                return e;
            }
        };

        const rowsAffected = try self.removeFromDb(db, stderr);

        if (rowsAffected != 1) {
            try stderr.print(
                \\Error: Failed to remove migration from table zmm_migrations.
                \\Tried to remove 1 row with timestamp {d} and name "{s}", but removed {d} rows instead
                \\
            ,
                .{ self.timestamp, self.name, rowsAffected },
            );
            return error.FailedToRemoveMigrationRow;
        }

        try db.exec("COMMIT TRANSACTION;", .{}, .{});
        try stdout.writeAll("Success\n");
    }

    pub fn removeFromDb(self: @This(), db: *sqlite.Db, stderr: anytype) !usize {
        var diags: sqlite.Diagnostics = .{};
        db.exec(
            "DELETE FROM zmm_migrations WHERE timestamp = ? AND name = ?;",
            .{ .diags = &diags },
            .{ self.timestamp, self.name },
        ) catch |e| {
            try stderr.print("\n{s}\n", .{diags});
            return e;
        };

        return db.rowsAffected();
    }

    fn intoDatabaseMigration(self: @This()) utils.DatabaseMigration {
        return .{
            .name = self.name,
            .timestamp = self.timestamp,
            .up_md5 = self.up_md5,
            .down_md5 = self.down_md5,
        };
    }

    pub fn insertIntoDb(self: @This(), db: *sqlite.Db, stderr: anytype) !void {
        var diags: sqlite.Diagnostics = .{};
        utils.insertMigrationIntoTable(db, &diags, self.intoDatabaseMigration()) catch |e| {
            try stderr.print("{s}\n", .{diags});
            return e;
        };
    }
};

pub const MigrationDbRows = struct {
    arena: std.heap.ArenaAllocator,
    migrations: []const DbRow,

    pub fn deinit(self: *const @This()) void {
        self.arena.deinit();
    }

    pub fn fromDb(
        alloc: Allocator,
        db: *sqlite.Db,
        stderr: anytype,
        comptime order: []const u8,
    ) !@This() {
        var diags: sqlite.Diagnostics = .{};
        var stmt = db.prepareWithDiags(
            "select * from zmm_migrations ORDER BY timestamp " ++ order ++ ";",
            .{ .diags = &diags },
        ) catch |e| {
            try stderr.print("{any}\n", .{diags});
            return e;
        };
        defer stmt.deinit();

        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        // This is because the hashes are stored as strings, not as numbers
        const IntermediateRow = struct {
            name: []const u8,
            timestamp: u64,
            up_md5: []u8,
            down_md5: []u8,
        };
        var subArena = std.heap.ArenaAllocator.init(arena.allocator());
        const rows = stmt.all(IntermediateRow, subArena.allocator(), .{ .diags = &diags }, .{}) catch |e| {
            try stderr.print("{any}\n", .{diags});
            return e;
        };
        defer subArena.deinit();

        var list = try std.ArrayList(DbRow).initCapacity(arena.allocator(), rows.len);
        for (rows) |_row| {
            const row: IntermediateRow = _row;
            const up_md5 = if (row.up_md5.len == digest_length)
                @as(*[digest_length]u8, @ptrCast(row.up_md5.ptr)).*
            else {
                try stderr.print(
                    "While reading row {d}-{s} from database, up migration md5" ++
                        " is of incorrect length. It should be {} but is {}. Either" ++
                        " your database is corrupted, or this is a bug in zig-mig",
                    .{ row.timestamp, row.name, digest_length, row.up_md5.len },
                );
                return error.asdsadds;
            };

            const down_md5 = if (row.down_md5.len == digest_length)
                @as(*[digest_length]u8, @ptrCast(row.down_md5.ptr)).*
            else {
                try stderr.print(
                    "While reading row {d}-{s} from database, down migration md5" ++
                        " is of incorrect length. It should be {} but is {}. Either" ++
                        " your database is corrupted, or this is a bug in zig-mig",
                    .{ row.timestamp, row.name, digest_length, row.down_md5.len },
                );
                return error.asdsadds;
            };
            try list.append(.{
                .name = row.name,
                .timestamp = row.timestamp,
                .up_md5 = @bitCast(up_md5),
                .down_md5 = @bitCast(down_md5),
            });
        }

        return .{ .arena = arena, .migrations = list.items };
    }

    pub fn fromDbOldestFirst(alloc: Allocator, db: *sqlite.Db, stderr: anytype) !@This() {
        return fromDb(alloc, db, stderr, "ASC");
    }

    pub fn fromDbNewestFirst(alloc: Allocator, db: *sqlite.Db, stderr: anytype) !@This() {
        return fromDb(alloc, db, stderr, "DESC");
    }
};
