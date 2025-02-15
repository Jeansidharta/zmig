const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const utils = @import("utils.zig");
const digest_length = std.crypto.hash.Md5.digest_length;

pub const DbRow = struct {
    name: []const u8,
    timestamp: u64,
    up_md5: [digest_length]u8,
    down_md5: [digest_length]u8,

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
            if (!utils.expectHashBuf(downMigration, &self.down_md5)) {
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

    pub fn insertIntoDb(self: @This(), db: *sqlite.Db, stderr: anytype) !void {
        var diags: sqlite.Diagnostics = .{};
        db.exec(
            \\ INSERT INTO zmm_migrations (
            \\   name,
            \\   timestamp,
            \\   up_md5,
            \\   down_md5
            \\ ) VALUES (?, ?, ?, ?);
        , .{ .diags = &diags }, .{
            self.name,
            self.timestamp,
            self.up_md5,
            self.down_md5,
        }) catch |e| {
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

        var arena = std.heap.ArenaAllocator.init(alloc);
        const migrations = stmt.all(DbRow, arena.allocator(), .{
            .diags = &diags,
        }, .{}) catch |e| {
            try stderr.print("{any}\n", .{diags});
            return e;
        };

        return .{ .arena = arena, .migrations = migrations };
    }

    pub fn fromDbOldestFirst(alloc: Allocator, db: *sqlite.Db, stderr: anytype) !@This() {
        return fromDb(alloc, db, stderr, "ASC");
    }

    pub fn fromDbNewestFirst(alloc: Allocator, db: *sqlite.Db, stderr: anytype) !@This() {
        return fromDb(alloc, db, stderr, "DESC");
    }
};
