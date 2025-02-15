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

    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();

    var migrationsDir = std.fs.cwd().makeOpenPath(migrationsDirPath, .{ .iterate = true }) catch |e| {
        try stderr.print(
            "Failed to create migrations directory at path \"{s}\": {}",
            .{ migrationsDirPath, e },
        );
        return e;
    };
    defer migrationsDir.close();

    if (try utils.hasMigrationWithName(migrationsDir, migrationName)) {
        try stderr.print("Migration with provided name {s} already exists.", .{migrationName});
        if (options.allowDuplicateName) {
            try stderr.writeAll(" Option allow-duplicate-name was provided. Ignoring...\n");
        } else {
            try stderr.writeAll("\n");
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
        return e;
    };
    defer upFile.close();

    const downFile = migrationsDir.createFile(downFullName, .{}) catch |e| {
        try stderr.print(
            "Failed to create migration file at \"{s}/{s}\": {}",
            .{ migrationsDirPath, downFullName, e },
        );
        return e;
    };
    defer downFile.close();

    // === Write header to up and down files ===

    const upWriter = upFile.writer();
    const downWriter = downFile.writer();

    try upWriter.print("-- Up migration {s}\n", .{migrationName});
    try downWriter.print("-- Down migration {s}\n", .{migrationName});

    // Add description to the up migration, if it is provided
    if (options.description) |description| {
        try upWriter.print("--\n--", .{});

        var wordsIter = std.mem.splitAny(u8, description, " \t");
        var currentLineLen: usize = 0;
        while (wordsIter.next()) |word| {
            const wordLen = word.len + 1; // Add one for the space

            // If the line were to go over 80 characters, start a new line
            const maxLineLen = 80;
            const isFirstWordInLine = currentLineLen == 0;
            const isLineTooLong = currentLineLen + wordLen > maxLineLen;
            if (!isFirstWordInLine and isLineTooLong) {
                try upWriter.writeAll("\n--");
                currentLineLen = 0;
            }

            currentLineLen += wordLen;
            try upWriter.print(" {s}", .{word});
        }
    }

    try stdout.print(
        "Succesfuly created migration at \"{s}/{s}\"\n",
        .{ migrationsDirPath, upFullName },
    );
}
