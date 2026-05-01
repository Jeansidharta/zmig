const std = @import("std");
const utils = @import("src/utils.zig");
const sqlite = @import("sqlite");

const TMP_DIR = "/tmp/zmig-test";
const MIGRATIONS_DIR = TMP_DIR ++ "/migrations";
const DB_PATH = TMP_DIR ++ "/db.sqlite3";

fn up(alloc: std.mem.Allocator, io: std.Io) !void {
    const up_mod = @import("src/commands/up.zig");
    try up_mod.run(alloc, io, MIGRATIONS_DIR, DB_PATH);
}

fn down(alloc: std.mem.Allocator, io: std.Io) !void {
    const down_mod = @import("src/commands/down.zig");
    try down_mod.run(alloc, io, MIGRATIONS_DIR, DB_PATH);
}

fn check(alloc: std.mem.Allocator, io: std.Io) !void {
    const check_mod = @import("src/commands/check.zig");
    try check_mod.run(alloc, io, MIGRATIONS_DIR, DB_PATH);
}

fn newMigration(alloc: std.mem.Allocator, io: std.Io, migration_name: []const u8, up_migration: []const u8, down_migration: []const u8) !void {
    const new_migration_mod = @import("src/commands/new-migration.zig");
    new_migration_mod.options.migrationName = migration_name;
    const migration = try new_migration_mod.run(alloc, io, MIGRATIONS_DIR);
    defer alloc.free(migration.upFullName);
    defer alloc.free(migration.downFullName);

    const up_path = try std.fs.path.join(alloc, &.{ MIGRATIONS_DIR, migration.upFullName });
    defer alloc.free(up_path);
    const down_path = try std.fs.path.join(alloc, &.{ MIGRATIONS_DIR, migration.downFullName });
    defer alloc.free(down_path);

    {
        const up_file = try std.Io.Dir.openFileAbsolute(io, up_path, .{ .mode = .write_only });
        defer up_file.close(io);
        try up_file.writeStreamingAll(io, up_migration);
    }
    {
        const down_file = try std.Io.Dir.openFileAbsolute(io, down_path, .{ .mode = .write_only });
        defer down_file.close(io);
        try down_file.writeStreamingAll(io, down_migration);
    }
}

fn makeTmpDir(io: std.Io) !void {
    std.Io.Dir.createDirAbsolute(io, TMP_DIR, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    std.Io.Dir.createDirAbsolute(io, MIGRATIONS_DIR, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    const file = try std.Io.Dir.createFileAbsolute(io, DB_PATH, .{});
    file.close(io);
}

fn cleanup(io: std.Io) !void {
    try std.Io.Dir.cwd().deleteTree(io, TMP_DIR);
}

pub fn main(init: std.process.Init) !void {
    try cleanup(init.io);
    try makeTmpDir(init.io);

    const alloc = init.gpa;

    std.log.debug("Running empty up", .{});
    try up(alloc, init.io);

    std.log.debug("Creating Migrations Pair mig_1", .{});
    try newMigration(alloc, init.io, "mig_1",
        \\ CREATE TABLE Foo (col INTEGER PRIMARY KEY);
        \\ INSERT INTO Foo (col) VALUES (1);
    ,
        \\ DELETE FROM Foo WHERE col = 1;
        \\ DROP TABLE Foo;
    );

    std.log.debug("Running up for mig_1", .{});
    try up(alloc, init.io);

    std.log.debug("Running check", .{});
    try check(alloc, init.io);

    std.log.debug("Running down for mig_1", .{});
    try down(alloc, init.io);

    std.log.debug("Running up for mig_1", .{});
    try up(alloc, init.io);

    std.log.debug("Creating Migrations Pair mig_2", .{});
    try newMigration(alloc, init.io, "mig_2",
        \\ CREATE TABLE Bar (pol TEXT PRIMARY KEY);
        \\ INSERT INTO Bar (pol) VALUES ('FooBar');
    ,
        \\ DELETE FROM Bar WHERE pol = 'FooBar';
        \\ DROP TABLE Bar;
    );
    std.log.debug("Running up for mig_2", .{});
    try up(alloc, init.io);
    std.log.debug("Running Check", .{});
    try check(alloc, init.io);
    std.log.debug("Running down", .{});
    try down(alloc, init.io);

    std.log.debug("Running down", .{});
    try cleanup(init.io);
    std.log.debug("Test ran successfuly", .{});
}
