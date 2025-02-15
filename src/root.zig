// const std = @import("std");
// const sqlite = @import("sqlite");
//
// pub fn loadAllMigrations() []const []const u8 {
//     comptime {
//         var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
//         const alloc = gpa.allocator();
//         defer {
//             if (gpa.deinit() == .leak) {
//                 std.log.err("Memory leak detected", .{});
//             }
//         }
//
//         const dir = try std.fs.cwd().openDir("migrations", .{ .iterate = true });
//         const iter = dir.iterate();
//         const names = std.ArrayList([]const u8).init(alloc);
//         while (try iter.next()) |entry| {
//             try names.append(entry.name);
//         }
//         std.debug.print("{any}", .{names});
//         // @embedFile(path);
//     }
// }
//
// pub fn applyMigrations() void {}
