# zmig

A sqlite migration tool for Zig. Inspired by
[sqlx](https://github.com/launchbadge/sqlx).

zmig will create, verify and manage all your migrations while developing your
application. And when you deploy it, zmig will make sure your production app
will also run all migrations you wrote when developing it.

## Installing

1. Add it to your `build.zig.zon`:
   `zig fetch --save git+https://github.com/jeansidharta/zmig`

2. Add the module to your imports table in `build.zig`:

   ```zig
   // ... Previous things in your build.zig file...
   const zmig = b.dependency("zmig", .{
      .target = target,
      .optimize = optimize,
   });
   // Note: exe is your main application executable module
   exe_mod.root_module.addImport("zmig", zmig.module("zmig"));
   // ... Remaining things in you build.zig file...
   ```

3. Setup the migrations directory to be used by zmig:
   ```zig
   {
       // You can replace "migrations" with any other name of a directory where you're storing your migrations.
       const migrations_dir = b.path("migrations");
       const clone_migrations_step = zmig.builder.named_writefiles.get("clone_migrations").?;
       _ = clone_migrations_step.addCopyDirectory(migrations_dir, "", .{ .include_extensions = &.{".sql"} });
   }
   ```
4. (optional. Skip if you don't want to use the zmig-cli) Expose the zmig-cli
   executable in your `build.zig`:
   ```zig
    {
       const zmig_cli = b.addRunArtifact(
           b.addExecutable(.{
               .root_module = zmig.module("zmig-cli"),
               // Enabled due to https://github.com/vrischmann/zig-sqlite/issues/195
               .use_llvm = true,
               .name = "zmig-cli",
           }),*
       );
       const run_zmig_cli = b.step("zmig", "Invokes the zmig-cli tool");
       run_zmig_cli.dependOn(&zmig_cli.step);
       zmig_cli.addArgs(b.args orelse &.{});
    }
   ```

See the [examples](https://github.com/Jeansidharta/zmig/tree/main/examples)
directory to see it in action

## Usage

zmig has two usage components: the zig module and the cli tool.

### The CLI

The zmig-cli tool will help you create and debug your migrations. It is not
necessary, as it will mostly just create migration templates and run them on a
target database (something your application will already do on its own), but it
might be helpful during development.

If you've followed the installation steps 1 through 4 (don't forget step 4!) you
should be able to invoke the zmig-cli tool by running
`zig build zmig -- --help`. Any argument after the `--` will be directed towards
the zmig-cli tool. The help messages should be enought to help you learn the
tool.

A simple possible workflow would be something like this:

```console
# The CLI uses this environment variable to determine the path to the
# local database. If preferable, you can also pass this path in the
# -d option (ex: `zig build zmig -- -d db.sqlite3 check`)
$ export ZMM_DB_PATH=db.sqlite3

# Creates a new migration named "migration_name"
# You can also specify a different migrations directory with the -m option
$ zig build zmig -- new migration_name

Succesfuly created migration at "migrations/1758503588032-migration_name.up.sql"

# Edit the migration with the changes we want
$ vim migrations/1758503588032-migration_name.up.sql
# Don't forget to write a proper down migration!
$ vim migrations/1758503588032-migration_name.down.sql

# Apply the new migration to our local database
$ zig build zmig -- up

Looking for migrations at "migrations" directory...
1 migration to apply...
Applying migration 1758503588032-migration_name.up.sql... Success

# Check if all migrations are applied, and if everything looks good.
$ zig build zmig -- check

Looking for migrations at "migrations" directory...
No migrations to apply
Everything is Ok!

# Down the last applied migration. You can provice a count with the -c option.
$ zig build zmig -- down

Looking for migrations at "migrations" directory...
Applying migration "1758503588032-migration_name.down.sql"... Success

```

### The zig module

The zig module is included in your application's final binary, and has all the
necessary tools and information to apply your migrations to a new database.

Make sure you followed the installation steps 1 through 3.

The zmig module only has one exported function:
`fn applyMigrations(db: *sqlite.Db, alloc: Allocator, options: Options) !void`.
This function will make sure all migrations in the directory specified in the
step 3 of the installation have been correctly applied to the given SQLite
database. If any migration still has to be applied, it will apply it for you.
**All allocated memory is freed before the function returns, so no cleanup is
necessary**.

The third argument, `Options`, is a struct with the following format:

```zig
const Options = struct {
    checkHash: bool = false,
    checkName: bool = false,
    diagnostics: ?*Diagnostics = null,
};
```

If `checkHash` is set to true, the `applyMigrations` function will error if any
previously applied migration has a differenty hash from its current
correspondent migration file. If `checkName` is true, it will also error if
there is a name mismatch. This is useful if you want to make sure no migration
has been modified since it's been applied. Should probably be turned off for
production, though, unless you have a decent way to recover from this.

If the `diagnostics` field is provided, it'll be populated with additional
information in case an error occurs. This is known as the
[diagnostics pattern](https://mikemikeb.com/blog/zig_error_payloads/). The
diagnostics object has a custom `format` function that will display a friendly
message to the user indicating what went wrong. example:

```zig
var diagnostics: zmig.Diagnostics = .{};
zmig.applyMigrations(db, alloc, .{ .diagnostics = &diagnostics }) catch |e| {
    std.debug.print("{f}\n", .{diagnostics});
    return e;
}
```

Do note that the `applyMigrations` function does not directly read from the
specified migrations directory. It, instead, has those migrations embeded into
the application binary. This means that if you delete the specified migrations
folder, the previously built application binary will still have the old
migrations. The only way to update the migrations from the binary is by
rebuilding the application. This is useful so that the application will
automatically apply any needed migration when it is deployed to production.
