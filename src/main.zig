const std = @import("std");
const cli = @import("cli");

const commandNewMigration = @import("./commands/new-migration.zig");
const commandUp = @import("./commands/up.zig");
const commandDown = @import("./commands/down.zig");
const commandCheck = @import("./commands/check.zig");

fn exec() !void {}

var config = struct {
    dbPath: []const u8 = "",
    migrationsDirPath: []const u8 = "migrations",
}{};

var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
var alloc = gpa.allocator();

fn runNew() !void {
    const result = try commandNewMigration.run(alloc, config.migrationsDirPath);
    alloc.free(result.downFullName);
    alloc.free(result.upFullName);
}

fn runUp() !void {
    const dbPath = try alloc.dupeZ(u8, config.dbPath);
    defer alloc.free(dbPath);

    try commandUp.run(alloc, config.migrationsDirPath, dbPath);
}

fn runDown() !void {
    const dbPath = try alloc.dupeZ(u8, config.dbPath);
    defer alloc.free(dbPath);

    try commandDown.run(alloc, config.migrationsDirPath, dbPath);
}

fn runCheck() !void {
    const dbPath = try alloc.dupeZ(u8, config.dbPath);
    defer alloc.free(dbPath);

    try commandCheck.run(alloc, config.migrationsDirPath, dbPath);
}

pub fn main() !void {
    var runner = try cli.AppRunner.init(alloc);
    const app = cli.App{
        .version = "0.0.1",
        .author = "jeansidharta@gmail.com",
        .command = .{
            .name = "zmig",
            .description = .{
                .one_line = "Manage sqlite migrations",
                .detailed = "Zig Migration Manager allows you to easily create, apply and remove migrations on your SQLite database.",
            },
            .options = try runner.allocOptions(&.{
                cli.Option{
                    .long_name = "database",
                    .short_alias = 'd',
                    .envvar = "ZMIG_DB_PATH",
                    .help = "Path to the database",
                    .required = true,
                    .value_name = "DB-PATH",
                    .value_ref = runner.mkRef(&config.dbPath),
                },
                cli.Option{
                    .long_name = "migrations-path",
                    .short_alias = 'm',
                    .envvar = "ZMIG_MIGRATIONS_PATH",
                    .help = "Path to the directory that contains the migrations",
                    .value_name = "MIGRATIONS-DIR",
                    .value_ref = runner.mkRef(&config.migrationsDirPath),
                },
            }),
            .target = .{
                .subcommands = try runner.allocCommands(&.{
                    cli.Command{
                        .name = "new",
                        .description = .{ .one_line = "Creates a new migration file" },
                        .options = try runner.allocOptions(&.{
                            cli.Option{
                                .long_name = "description",
                                .help = "A short description to the migration",
                                .short_alias = 's',
                                .value_ref = runner.mkRef(&commandNewMigration.options.description),
                            },
                            cli.Option{
                                .long_name = "allow-duplicate-name",
                                .help = "Allows migrations to have the same name",
                                .envvar = "ZMIG_ALLOW_DUPLICATE_NAME",
                                .value_ref = runner.mkRef(&commandNewMigration.options.allowDuplicateName),
                            },
                        }),
                        .target = .{
                            .action = .{
                                .positional_args = .{
                                    .required = try runner.allocPositionalArgs(&.{
                                        cli.PositionalArg{
                                            .name = "migration_name",
                                            .help = "A short migration name",
                                            .value_ref = runner.mkRef(&commandNewMigration.options.migrationName),
                                        },
                                    }),
                                },
                                .exec = runNew,
                            },
                        },
                    },
                    cli.Command{
                        .name = "up",
                        .description = .{ .one_line = "Runs the up migrations" },
                        .options = try runner.allocOptions(&.{
                            cli.Option{
                                .long_name = "count",
                                .short_alias = 'c',
                                .help = "How many up migrations to run. Runs all by default.",
                                .value_ref = runner.mkRef(&commandUp.options.numberOfMigrations),
                            },
                            cli.Option{
                                .long_name = "ignore-hash-differences",
                                .help = "Whether to ignore hash differences in migration files. Defalt: false",
                                .value_ref = runner.mkRef(&commandUp.options.ignoreHashDifferences),
                            },
                        }),
                        .target = .{
                            .action = .{
                                .exec = runUp,
                            },
                        },
                    },
                    cli.Command{
                        .name = "down",
                        .description = .{ .one_line = "Runs the down migrations" },
                        .options = try runner.allocOptions(&.{
                            cli.Option{
                                .long_name = "count",
                                .short_alias = 'c',
                                .help = "How many down migrations to run. Default: 1",
                                .value_ref = runner.mkRef(&commandDown.options.numberOfMigrations),
                            },
                            cli.Option{
                                .long_name = "ignore-hash-differences",
                                .help = "Whether to ignore hash differences in migration files. Defalt: false",
                                .value_ref = runner.mkRef(&commandDown.options.ignoreHashDifferences),
                            },
                        }),
                        .target = .{
                            .action = .{
                                .exec = runDown,
                            },
                        },
                    },
                    cli.Command{
                        .name = "check",
                        .description = .{
                            .one_line = "Check for issues with migrations",
                            .detailed =
                            \\Verifies everything is ok with all migrations. It will verify the following items, in this order:
                            \\- Migrations directory exists.
                            \\- Database exists
                            \\- Migrations table exists
                            \\- For each migration in the database:
                            \\  - Corresponding file for the up and down migrations exists in the migrations directory.
                            \\  - The up and down files's hash matches the ones in the database.
                            \\  - There are no migration files inbetween database rows.
                            \\If there are any migrations that have not yet been applied, list them
                            ,
                        },
                        .options = try runner.allocOptions(&.{}),
                        .target = .{
                            .action = .{
                                .exec = runCheck,
                            },
                        },
                    },
                }),
            },
        },
    };
    // For some reason, the application segfaults when deiniting the runner.
    // It'd be good to investigate why, but for now, leaking this is no big deal.
    // defer runner.deinit();

    _ = runner.run(&app) catch {};
}
