const std = @import("std");
const cli = @import("zig-cli");

fn exec() !void {}

var config = struct {
    dbPath: []const u8 = "",
    migrationsDirPath: []const u8 = "migrations",
}{};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var runner = try cli.AppRunner.init(alloc);
    const app = cli.App{
        .version = "0.0.1",
        .author = "jeansidharta@gmail.com",
        .command = .{
            .name = "zmm",
            .description = .{
                .one_line = "Manage sqlite migrations",
                .detailed = "Zig Migration Manager allows you to easily create, apply and remove migrations on your SQLite database.",
            },
            .options = &.{
                cli.Option{
                    .long_name = "database",
                    .short_alias = 'd',
                    .envvar = "ZMM_DB_PATH",
                    .help = "Path to the database",
                    .required = true,
                    .value_name = "DB-PATH",
                    .value_ref = runner.mkRef(&config.dbPath),
                },
                cli.Option{
                    .long_name = "migrations-path",
                    .short_alias = 'm',
                    .envvar = "ZMM_MIGRATIONS_PATH",
                    .help = "Path to the directory that contains the migrations",
                    .value_name = "MIGRATIONS-DIR",
                    .value_ref = runner.mkRef(&config.migrationsDirPath),
                },
            },
            .target = .{
                .subcommands = &.{
                    cli.Command{
                        .name = "new",
                        .description = .{ .one_line = "Creates a new migration file" },
                        .target = .{
                            .action = .{
                                .positional_args = .{
                                    .required = &.{
                                        cli.PositionalArg{
                                            .name = "migration_name",
                                            .help = "A short migration name",
                                        },
                                    },
                                },
                            },
                        },
                    },
                    cli.Command{
                        .name = "up",
                        .description = .{ .one_line = "Applies all up migrations" },
                    },
                    cli.Command{
                        .name = "down",
                        .description = .{ .one_line = "Applies a single down migration" },
                    },
                },
            },
        },
    };
    defer runner.deinit();

    try runner.run(&app);
}
