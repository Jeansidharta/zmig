const std = @import("std");
const utils = @import("./utils.zig");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const digest_length = std.crypto.hash.Md5.digest_length;

const DbRow = @import("./migration-db-rows.zig").DbRow;

const IntermediaryMigrationFilePair = struct {
    timestamp: u64,
    name: []const u8,
    upFilename: ?[]const u8,
    downFilename: ?[]const u8,

    dir: std.fs.Dir,

    pub fn intoMigrationFilePair(self: @This()) !MigrationFilePair {
        if (self.upFilename) |upFilename| {
            if (self.downFilename) |downFilename| {
                return .{
                    .timestamp = self.timestamp,
                    .name = self.name,
                    .upFilename = upFilename,
                    .downFilename = downFilename,
                    .dir = self.dir,
                };
            } else return error.MissingDownFile;
        } else return error.MissingUpFile;
    }

    pub fn fromFileName(
        alloc: Allocator,
        migrationDir: std.fs.Dir,
        entryName: []const u8,
        stderr: anytype,
    ) !@This() {
        const filename = try alloc.dupe(u8, entryName);
        errdefer alloc.free(filename);

        const parsed = utils.parseFileName(filename) catch |e| {
            switch (e) {
                error.MissingTimestamp => try stderr.print(
                    "Missing typestamp section in migration file name {s}\n",
                    .{filename},
                ),
                error.MissingName => try stderr.print(
                    "Missing name section in migration file name {s}\n",
                    .{filename},
                ),
                error.InvalidTimestamp => try stderr.print(
                    "Invalid timestamp section in filename {s}\n",
                    .{filename},
                ),
                error.InvalidExtension => try stderr.print(
                    "Invalid extension for file \"{s}\". Should either be .up.sql or .down.sql\n",
                    .{filename},
                ),
            }
            return e;
        };
        return .{
            .name = parsed.name,
            .timestamp = parsed.timestamp,
            .upFilename = if (parsed.typ == .up) filename else null,
            .downFilename = if (parsed.typ == .down) filename else null,
            .dir = migrationDir,
        };
    }
};

fn findIntermediaryWithTimestamp(
    pairs: []const IntermediaryMigrationFilePair,
    timestamp: u64,
) ?*IntermediaryMigrationFilePair {
    for (0..pairs.len) |index| {
        const invIndex = pairs.len - index - 1;
        if (pairs[invIndex].timestamp == timestamp)
            return @constCast(&pairs[invIndex]);
    }
    return null;
}

/// Represents an up and down pair file pair.
pub const MigrationFilePair = struct {
    timestamp: u64,
    name: []const u8,
    upFilename: []const u8,
    downFilename: []const u8,

    dir: std.fs.Dir,

    pub fn execUp(
        self: @This(),
        alloc: Allocator,
        db: *sqlite.Db,
        stderr: anytype,
    ) !void {
        const upContents = try self.readUp(alloc);
        defer alloc.free(upContents);

        var sqliteDiags: sqlite.Diagnostics = .{};
        try db.exec("BEGIN TRANSACTION;", .{}, .{});
        db.execDynamic(upContents, .{ .diags = &sqliteDiags }, .{}) catch |e| {
            try stderr.print("\n{s}\n", .{sqliteDiags});
            return e;
        };

        const migration = try self.intoDbRow(alloc);
        try migration.insertIntoDb(db, stderr);
        try db.exec("COMMIT TRANSACTION;", .{}, .{});
    }

    pub fn readUp(self: @This(), alloc: Allocator) ![]const u8 {
        return self.dir.readFileAlloc(alloc, self.upFilename, 1024 * 1024 * 256);
    }

    pub fn readDown(self: @This(), alloc: Allocator) ![]const u8 {
        return self.dir.readFileAlloc(alloc, self.downFilename, 1024 * 1024 * 256);
    }

    pub fn eqlNameAndTimestamp(self: @This(), row: DbRow) bool {
        return self.timestamp == row.timestamp and std.mem.eql(u8, row.name, self.name);
    }

    pub fn intoDbRow(
        self: @This(),
        alloc: Allocator,
    ) !DbRow {
        const up_md5 = up_md5: {
            const upContents = try self.readUp(alloc);
            defer alloc.free(upContents);
            break :up_md5 utils.hashBuf(upContents);
        };
        const down_md5 = down_md5: {
            const downContents = try self.readDown(alloc);
            defer alloc.free(downContents);
            break :down_md5 utils.hashBuf(downContents);
        };
        return .{
            .name = self.name,
            .timestamp = self.timestamp,
            .up_md5 = up_md5,
            .down_md5 = down_md5,
        };
    }
};

fn pairCompare(_: void, a: MigrationFilePair, b: MigrationFilePair) bool {
    return a.timestamp < b.timestamp;
}

/// This type is a wrapper around a PriorityQueue to allow for a clean deinit function
pub const MigrationFiles = struct {
    dir: std.fs.Dir,
    array: std.ArrayList(MigrationFilePair),
    alloc: Allocator,

    pub fn deinit(self: @This()) void {
        for (self.array.items) |item| {
            self.alloc.free(item.upFilename);
            self.alloc.free(item.downFilename);
        }
        self.array.deinit();
    }

    /// Lists all migrations in the MigrationDir
    pub fn fromDir(alloc: Allocator, migrationDir: std.fs.Dir, stderr: anytype) !@This() {
        var iter = migrationDir.iterate();
        var intermediaryArray = std.ArrayList(IntermediaryMigrationFilePair).init(alloc);
        defer intermediaryArray.deinit();

        while (try iter.next()) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;

            // TODO - this line allocates memory. If this function return an error,
            // the allocated memory will leak. This should probably be handled.
            const newMigration = try IntermediaryMigrationFilePair.fromFileName(
                alloc,
                migrationDir,
                entry.name,
                stderr,
            );

            if (findIntermediaryWithTimestamp(
                intermediaryArray.items,
                newMigration.timestamp,
            )) |oldMigration| {
                if (oldMigration.upFilename == null) {
                    oldMigration.upFilename = newMigration.upFilename;
                } else {
                    oldMigration.downFilename = newMigration.downFilename;
                }
            } else {
                try intermediaryArray.append(newMigration);
            }
        }

        var self: @This() = .{
            .array = try .initCapacity(alloc, intermediaryArray.items.len),
            .alloc = alloc,
            .dir = migrationDir,
        };
        errdefer self.array.deinit();

        for (intermediaryArray.items) |pair| {
            const newPair = pair.intoMigrationFilePair() catch |e| {
                switch (e) {
                    error.MissingDownFile => try stderr.print(
                        "Down migration \"{s}\" has no correspondingg up migration\n",
                        .{pair.downFilename.?},
                    ),
                    error.MissingUpFile => try stderr.print(
                        "Up migration \"{s}\" has no correspondingg down migration\n",
                        .{pair.downFilename.?},
                    ),
                }
                return e;
            };
            try self.array.append(newPair);
        }
        std.sort.insertion(MigrationFilePair, @constCast(self.array.items), {}, pairCompare);
        return self;
    }
};
