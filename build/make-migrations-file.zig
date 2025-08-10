const std = @import("std");
const utils = @import("utils");
const module_options = @import("options");
const digest_length = std.crypto.hash.Md5.digest_length;

const HashInt = std.meta.Int(.unsigned, digest_length * 8);

const File = struct {
    name: []const u8,
    body: []const u8,
    timestamp: u64,
    hash: HashInt,

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            \\    .{{
            \\        .timestamp = {d},
            \\        .name = "{s}",
            \\        .up_hash = 0x{x},
            \\        .body =
            \\
        , .{ self.timestamp, self.name, self.hash });
        var iter = std.mem.splitScalar(u8, self.body, '\n');
        while (iter.next()) |line| {
            try writer.print("        \\\\{s}\n", .{line});
        }

        try writer.print(
            \\        ,
            \\    }},
        , .{});
    }
};
const Migrations = struct {
    arr: std.ArrayList(File),

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            \\pub const Migration = struct {{
            \\    timestamp: u64,
            \\    name: []const u8,
            \\    up_hash: u{},
            \\    body: []const u8,
            \\}};
            \\pub const MIGRATIONS: []const Migration = &.{{
            \\
        , .{digest_length * 8});
        for (self.arr.items) |file| {
            try writer.print("{s}\n", .{file});
        }
        try writer.writeAll(
            \\};
        );
    }

    pub fn init(alloc: std.mem.Allocator) @This() {
        return .{ .arr = .init(alloc) };
    }
};

fn pairCompare(_: void, a: File, b: File) bool {
    return std.ascii.orderIgnoreCase(a.name, b.name) == .lt;
}

const ParseFileNameError = error{
    MissingTimestamp,
    MissingName,
    InvalidTimestamp,
};

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const stderr = std.io.getStdErr().writer();

    const args = try std.process.argsAlloc(alloc);
    if (args.len != 3) @panic("Wrong number of arguments");

    const migrationsDirPath = args[1];
    const outputFilePath = args[2];

    const outputFile = try std.fs.createFileAbsolute(outputFilePath, .{ .truncate = false });
    defer outputFile.close();

    const outputWriter = outputFile.writer();

    const dir = std.fs.cwd().openDir(migrationsDirPath, .{ .iterate = true }) catch |e| {
        try stderr.print("Failed to open migrations directory: {}\n", .{e});
        return e;
    };

    var iter = dir.iterate();
    var files: Migrations = .init(alloc);
    while (try iter.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".up.sql")) continue;
        const filename = try alloc.dupe(u8, entry.name);
        const parsed = try utils.parseFileName(filename);
        const body = try dir.readFileAlloc(alloc, entry.name, 256 * 1024 * 1024);
        const hash: HashInt = @bitCast(utils.hashBuf(body));
        try files.arr.append(.{
            .timestamp = parsed.timestamp,
            .name = parsed.name,
            .hash = hash,
            .body = body,
        });
    }
    std.sort.insertion(File, @constCast(files.arr.items), {}, pairCompare);
    try outputWriter.print("{}", .{files});
}
