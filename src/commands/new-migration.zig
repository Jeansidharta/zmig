const std = @import("std");
const utils = @import("../utils.zig");

const Allocator = std.mem.Allocator;

/// Global variable that contains options specific to the `new` command.
pub var options = struct {
    migrationName: []const u8 = undefined,
    description: ?[]const u8 = null,
    allowDuplicateName: bool = false,
}{};

pub fn run(
    alloc: Allocator,
    migrationsDirPath: []const u8,
) !void {
    const migrationName = options.migrationName;

    var stderr_writer = std.fs.File.stderr().writer(&.{});
    const stderr = &stderr_writer.interface;

    var stdout_writer = std.fs.File.stderr().writer(&.{});
    const stdout = &stdout_writer.interface;

    var migrationsDir = std.fs.cwd().makeOpenPath(migrationsDirPath, .{ .iterate = true }) catch |e| {
        try stderr.print(
            "Failed to create migrations directory at path \"{s}\": {}",
            .{ migrationsDirPath, e },
        );
        try stderr.flush();
        return e;
    };
    defer migrationsDir.close();

    if (try utils.hasMigrationWithName(migrationsDir, migrationName)) {
        try stderr.print("Migration with provided name {s} already exists.", .{migrationName});
        if (options.allowDuplicateName) {
            try stderr.writeAll(" Option allow-duplicate-name was provided. Ignoring...\n");
            try stderr.flush();
        } else {
            try stderr.writeAll("\n");
            try stderr.flush();
            return error.MigrationAlreadyExists;
        }
    }

    // === Create Up and Down file names ===
    const time = std.time.milliTimestamp();
    const upFullName = try std.fmt.allocPrint(
        alloc,
        "{d}-{s}.up.sql",
        .{ time, migrationName },
    );
    defer alloc.free(upFullName);
    const downFullName = try std.fmt.allocPrint(
        alloc,
        "{d}-{s}.down.sql",
        .{ time, migrationName },
    );
    defer alloc.free(downFullName);

    const upFile = migrationsDir.createFile(upFullName, .{}) catch |e| {
        try stderr.print(
            "Failed to create migration file at \"{s}/{s}\": {}",
            .{ migrationsDirPath, upFullName, e },
        );
        try stderr.flush();
        return e;
    };
    defer upFile.close();

    const downFile = migrationsDir.createFile(downFullName, .{}) catch |e| {
        try stderr.print(
            "Failed to create migration file at \"{s}/{s}\": {}",
            .{ migrationsDirPath, downFullName, e },
        );
        try stderr.flush();
        return e;
    };
    defer downFile.close();

    // === Write header to up and down files ===

    var up_writer = upFile.writer(&.{});
    const up = &up_writer.interface;
    var down_writer = downFile.writer(&.{});
    const down = &down_writer.interface;

    try up.print("-- Up migration {s}\n", .{migrationName});
    try up.flush();
    try down.print("-- Down migration {s}\n", .{migrationName});
    try down.flush();

    // Add description to the up migration, if it is provided
    if (options.description) |description| {
        try up.print("--\n--", .{});
        try up.flush();

        var wordsIter = std.mem.splitAny(u8, description, " \t");
        var currentLineLen: usize = 0;
        while (wordsIter.next()) |word| {
            const wordLen = word.len + 1; // Add one for the space

            // If the line were to go over 80 characters, start a new line
            const maxLineLen = 80;
            const isFirstWordInLine = currentLineLen == 0;
            const isLineTooLong = currentLineLen + wordLen > maxLineLen;
            if (!isFirstWordInLine and isLineTooLong) {
                try up.writeAll("\n--");
                try up.flush();
                currentLineLen = 0;
            }

            currentLineLen += wordLen;
            try up.print(" {s}", .{word});
            try up.flush();
        }
    }

    try stdout.print(
        "Succesfuly created migration at \"{s}/{s}\"\n",
        .{ migrationsDirPath, upFullName },
    );
    try stdout.flush();
}
