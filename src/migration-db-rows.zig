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
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
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
        try stdout.flush();

        try db.exec("BEGIN TRANSACTION;", .{}, .{});

        var diags: sqlite.Diagnostics = .{};
        db.execMulti(downMigration, .{ .diags = &diags }) catch |e| {
            if (e == error.EmptyQuery) {
                try stderr.print("\nWarning: migration \"{s}\" has an empty query\n", .{downFilename});
                try stderr.flush();
            } else {
                try stderr.print("\n{f}\n", .{diags});
                try stderr.flush();
                return e;
            }
        };

        const rowsAffected = try self.removeFromDb(db, stderr);

        if (rowsAffected != 1) {
            try stderr.print(
                \\Error: Failed to remove migration from table zmig_migrations.
                \\Tried to remove 1 row with timestamp {d} and name "{s}", but removed {d} rows instead
                \\
            ,
                .{ self.timestamp, self.name, rowsAffected },
            );
            try stderr.flush();
            return error.FailedToRemoveMigrationRow;
        }

        try db.exec("COMMIT TRANSACTION;", .{}, .{});
        try stdout.writeAll("Success\n");
        try stdout.flush();
    }

    pub fn removeFromDb(self: @This(), db: *sqlite.Db, stderr: *std.Io.Writer) !usize {
        var diags: sqlite.Diagnostics = .{};
        db.exec(
            "DELETE FROM zmig_migrations WHERE timestamp = ? AND name = ?;",
            .{ .diags = &diags },
            .{ self.timestamp, self.name },
        ) catch |e| {
            try stderr.print("\n{f}\n", .{diags});
            try stderr.flush();
            return e;
        };

        return db.rowsAffected();
    }

    pub fn insertIntoDb(self: @This(), db: *sqlite.Db, stderr: *std.Io.Writer) !void {
        var diags: sqlite.Diagnostics = .{};
        const up_md5 = @as([digest_length]u8, @bitCast(self.up_md5));
        const down_md5 = @as([digest_length]u8, @bitCast(self.down_md5));
        const migration: utils.DatabaseMigration = .{
            .name = self.name,
            .timestamp = self.timestamp,
            .up_md5 = .{ .data = &up_md5 },
            .down_md5 = .{ .data = &down_md5 },
        };
        utils.insertMigrationIntoTable(db, &diags, migration) catch |e| {
            try stderr.print("{f}\n", .{diags});
            try stderr.flush();
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
        stderr: *std.Io.Writer,
        comptime order: []const u8,
    ) !@This() {
        var diags: sqlite.Diagnostics = .{};
        var stmt = db.prepareWithDiags(
            "select * from zmig_migrations ORDER BY timestamp " ++ order ++ ";",
            .{ .diags = &diags },
        ) catch |e| {
            try stderr.print("{f}\n", .{diags});
            try stderr.flush();
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
            try stderr.print("{f}\n", .{diags});
            try stderr.flush();
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
                        " is of incorrect length. It should be {d} but is {d}. Either" ++
                        " your database is corrupted, or this is a bug in zig-mig",
                    .{ row.timestamp, row.name, digest_length, row.up_md5.len },
                );
                try stderr.flush();
                return error.asdsadds;
            };

            const down_md5 = if (row.down_md5.len == digest_length)
                @as(*[digest_length]u8, @ptrCast(row.down_md5.ptr)).*
            else {
                try stderr.print(
                    "While reading row {d}-{s} from database, down migration md5" ++
                        " is of incorrect length. It should be {d} but is {d}. Either" ++
                        " your database is corrupted, or this is a bug in zig-mig",
                    .{ row.timestamp, row.name, digest_length, row.down_md5.len },
                );
                try stderr.flush();
                return error.asdsadds;
            };
            try list.append(arena.allocator(), .{
                .name = row.name,
                .timestamp = row.timestamp,
                .up_md5 = @bitCast(up_md5),
                .down_md5 = @bitCast(down_md5),
            });
        }

        return .{ .arena = arena, .migrations = list.items };
    }

    pub fn fromDbOldestFirst(alloc: Allocator, db: *sqlite.Db, stderr: *std.Io.Writer) !@This() {
        return fromDb(alloc, db, stderr, "ASC");
    }

    pub fn fromDbNewestFirst(alloc: Allocator, db: *sqlite.Db, stderr: *std.Io.Writer) !@This() {
        return fromDb(alloc, db, stderr, "DESC");
    }
};
