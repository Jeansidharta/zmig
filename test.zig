const std = @import("std");
const utils = @import("src/utils.zig");
const sqlite = @import("sqlite");

const TMP_DIR = "/tmp/zmig-test";
const MIGRATIONS_DIR = TMP_DIR ++ "/migrations";
const DB_PATH = TMP_DIR ++ "/db.sqlite3";

fn up(alloc: std.mem.Allocator) !void {
    const up_mod = @import("src/commands/up.zig");
    try up_mod.run(alloc, MIGRATIONS_DIR, DB_PATH);
}

fn down(alloc: std.mem.Allocator) !void {
    const down_mod = @import("src/commands/down.zig");
    try down_mod.run(alloc, MIGRATIONS_DIR, DB_PATH);
}

fn check(alloc: std.mem.Allocator) !void {
    const check_mod = @import("src/commands/check.zig");
    try check_mod.run(alloc, MIGRATIONS_DIR, DB_PATH);
}

fn new_migration(alloc: std.mem.Allocator, migration_name: []const u8, up_migration: []const u8, down_migration: []const u8) !void {
    const new_migration_mod = @import("src/commands/new-migration.zig");
    new_migration_mod.options.migrationName = migration_name;
    const migration = try new_migration_mod.run(alloc, MIGRATIONS_DIR);
    defer alloc.free(migration.upFullName);
    defer alloc.free(migration.downFullName);

    const up_path = try std.fs.path.join(alloc, &.{ MIGRATIONS_DIR, migration.upFullName });
    defer alloc.free(up_path);
    const down_path = try std.fs.path.join(alloc, &.{ MIGRATIONS_DIR, migration.downFullName });
    defer alloc.free(down_path);

    {
        const up_file = try std.fs.openFileAbsolute(up_path, .{ .mode = .write_only });
        defer up_file.close();
        try up_file.writeAll(up_migration);
    }
    {
        const down_file = try std.fs.openFileAbsolute(down_path, .{ .mode = .write_only });
        defer down_file.close();
        try down_file.writeAll(down_migration);
    }
}

fn make_tmp_dir() !void {
    std.fs.makeDirAbsolute(TMP_DIR) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    std.fs.makeDirAbsolute(MIGRATIONS_DIR) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    const file = try std.fs.createFileAbsolute(DB_PATH, .{});
    file.close();
}

fn cleanup() !void {
    try std.fs.deleteTreeAbsolute(TMP_DIR);
}

pub fn main() !void {
    try cleanup();
    try make_tmp_dir();

    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const alloc = gpa.allocator();
    defer {
        if (gpa.deinit() == .leak) {
            std.log.err("Memory leak detected", .{});
        }
    }

    std.log.debug("Running empty up", .{});
    try up(alloc);

    std.log.debug("Creating Migrations Pair mig_1", .{});
    try new_migration(alloc, "mig_1",
        \\ CREATE TABLE Foo (col INTEGER PRIMARY KEY);
        \\ INSERT INTO Foo (col) VALUES (1);
    ,
        \\ DELETE FROM Foo WHERE col = 1;
        \\ DROP TABLE Foo;
    );

    std.log.debug("Running up for mig_1", .{});
    try up(alloc);

    std.log.debug("Running check", .{});
    try check(alloc);

    std.log.debug("Running down for mig_1", .{});
    try down(alloc);

    std.log.debug("Running up for mig_1", .{});
    try up(alloc);

    std.log.debug("Creating Migrations Pair mig_2", .{});
    try new_migration(alloc, "mig_2",
        \\ CREATE TABLE Bar (pol TEXT PRIMARY KEY);
        \\ INSERT INTO Bar (pol) VALUES ('FooBar');
    ,
        \\ DELETE FROM Bar WHERE pol = 'FooBar';
        \\ DROP TABLE Bar;
    );
    std.log.debug("Running up for mig_2", .{});
    try up(alloc);
    std.log.debug("Running Check", .{});
    try check(alloc);
    std.log.debug("Running down", .{});
    try down(alloc);

    std.log.debug("Running down", .{});
    try cleanup();
    std.log.debug("Test ran successfuly", .{});
}
