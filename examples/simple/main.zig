const std = @import("std");
const sqlite = @import("sqlite");
const zmig = @import("zmig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const alloc = gpa.allocator();

    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = "db.sqlite3" },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });
    defer db.deinit();

    try zmig.applyMigrations(&db, alloc, .{}, null);
}
