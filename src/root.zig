// const std = @import("std");
// const sqlite = @import("sqlite");
// const Allocator = std.mem.Allocator;
//
// const log = std.log.scoped(.migration);
//
// const MigrationFile = struct {
//     const Self = @This();
//     up: []const u8,
//     down: []const u8,
//
//     fn compare(_: void, lhs: Self, rhs: Self) bool {
//         return std.mem.order(u8, lhs.up, rhs.up).compare(std.math.CompareOperator.lt);
//     }
// };
// fn getMigrationFiles(alloc: Allocator, dir_path: []const u8) !std.ArrayList(MigrationFile) {
//     // Create and op;en the directory holding the migrations
//     var migrations_dir = std.fs.cwd().makeOpenPath(dir_path, .{
//         .iterate = true,
//     }) catch |e| {
//         log.debug("Error opening migration dir at {}: {}", .{ dir_path, e });
//         return e;
//     };
//     defer migrations_dir.close();
//
//     // Iterate over all files in the migrations directory and arrange
//     // them into up and down statements.
//     var migration_files_hash =
//         migration_files_hash: {
//         var hash = std.StringArrayHashMap(
//             struct { up: ?[]const u8 = null, down: ?[]const u8 = null },
//         ).init(alloc);
//
//         var iterator = migrations_dir.iterate();
//         while (try iterator.next()) |entry| {
//             switch (entry.kind) {
//                 .file => {
//                     const stem = std.fs.path.stem(entry.name);
//                     const stem2 = std.fs.path.stem(stem);
//                     const extension = std.fs.path.extension(entry.name);
//                     const extension2 = std.fs.path.extension(stem);
//                     if (std.mem.eql(u8, extension, ".up")) {
//                         if (hash.getPtr(stem)) |value| {
//                             if (value.up == null) {
//                                 value.up = entry.name;
//                             } else {
//                                 log.warn("Found duplicate up migration with name {}. Will ignore the second one.", .{stem});
//                             }
//                         } else {
//                             try hash.put(stem, .{ .up = entry.name });
//                         }
//                     } else if (std.mem.eql(u8, extension2, ".up")) {
//                         if (hash.getPtr(stem2)) |value| {
//                             if (value.up == null) {
//                                 value.up = entry.name;
//                             } else {
//                                 log.warn("Found duplicate up migration with name {}. Will ignore the second one.", .{stem2});
//                             }
//                         } else {
//                             try hash.put(stem2, .{ .up = entry.name });
//                         }
//                     } else if (std.mem.eql(u8, extension, ".down")) {
//                         if (hash.getPtr(stem)) |value| {
//                             if (value.down == null) {
//                                 value.down = entry.name;
//                             } else {
//                                 log.warn("Found duplicate down migration with name {}. Will ignore the second one.", .{stem});
//                             }
//                         } else {
//                             try hash.put(stem, .{ .down = entry.name });
//                         }
//                     } else if (std.mem.eql(u8, extension2, ".down")) {
//                         if (hash.getPtr(stem2)) |value| {
//                             if (value.down == null) {
//                                 value.down = entry.name;
//                             } else {
//                                 log.warn("Found duplicate down migration with name {}. Will ignore the second one.", .{stem2});
//                             }
//                         } else {
//                             try hash.put(stem2, .{ .down = entry.name });
//                         }
//                     } else {
//                         log.warn("File {} in migrations folder not identified as a migraiton. Skipping...", .{entry.name});
//                     }
//                 },
//                 else => {},
//             }
//         }
//         break :migration_files_hash hash;
//     };
//     defer migration_files_hash.deinit();
//
//     // Collect all migration files into an array
//     const migration_files = migration_files: {
//         var list = std.ArrayList(MigrationFile).init(alloc);
//         const hash_values = migration_files_hash.values();
//         for (hash_values) |value| {
//             if (value.up) |up| {
//                 if (value.down) |down| {
//                     try list.append(.{ .up = up, .down = down });
//                 } else log.err("Missing down migration for matching {}", .{up});
//             } else log.err("Missing up migration for matching {}", .{value.down.?});
//         }
//         break :migration_files list;
//     };
//
//     // Sort the migration files.
//     std.sort.insertion(MigrationFile, migration_files.items, {}, MigrationFile.compare);
//     return migration_files;
// }
//
// fn getMigrationFromDatabase(alloc: Allocator, db: *sqlite.Db) !std.ArrayList([]const u8) {
//     const query =
//         \\ SELECT
//         \\  name
//         \\ FROM migration ORDER BY name ASC
//     ;
//
//     var diags = sqlite.Diagnostics{};
//     var stmt = db.prepareWithDiags(query, .{ .diags = &diags }) catch |err| {
//         log.debug("unable to prepare statement, got error {}. diagnostics: {s}", .{ err, diags });
//         return err;
//     };
//     defer stmt.deinit();
//
//     var iterator = stmt.iterator([]const u8, .{}) catch |e| {
//         log.debug("Failed to fetch migrations from database", .{});
//         return e;
//     };
//
//     const names = std.ArrayList([]const u8).init(alloc);
//     while (try iterator.next(.{})) |name| {
//         names.append(name);
//     }
//     return names;
// }
//
// pub fn apply(alloc: Allocator, db: *sqlite.Db, migrations_dir_path: []const u8) !void {
//     db.exec(
//         \\ CREATE TABLE IF NOT EXISTS migration (
//         \\   stem_file_name TEXT NOT NULL PRIMARY KEY ASC,
//         \\   up_file_name TEXT NOT NULL,
//         \\   down_file_name TEXT NOT NULL,
//         \\   up_statement TEXT NOT NULL,
//         \\   down_statement TEXT NOT NULL
//         \\ )
//     , .{}, .{}) catch |e| {
//         log.debug("Error creating migrations table at {}: {}", .{ migrations_dir_path, e });
//         return e;
//     };
//
//     const migrations_files = try getMigrationFiles(alloc, migrations_dir_path);
//     defer migrations_files.deinit();
//     const migrations_rows = try getMigrationFromDatabase(alloc, db);
//     defer migrations_rows.deinit();
//
//     for (0..migrations_rows.len) |index| {}
// }
