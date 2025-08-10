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
   // Note: exe is your main application executable
   exe.root_module.addImport("zmig", zmig.module("zmig"));
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

### The zig module

Make sure you followed the installation steps 1 through 3.

The zmig module only has one exported function:
`fn applyMigrations(db: *sqlite.Db, alloc: Allocator, options: Options, diagnostics: ?*sqlite.Diagnostics) !void`.
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
};
```

If `checkHash` is set to true, the `applyMigrations` function will error if any
previously applied migration has a differenty hash from its current
correspondent migration file. If `checkName` is true, it will also error if
there is a name mismatch. This is useful if you wan't to make sure no migration
has been modified since it's been applied. Should probably be turned off for
production, though, unless you have a decent way to recover from this.

The fourth argument to the `applyMigrations` function, the `diagnostics` object,
is useful if you want to know more information about any potential errors;
Otherwise, you can just set it to null. The diagnostics object has a custom
`format` function that will display a friendly message to the user indicating
what went wrong.

Do note that the `applyMigrations` function does not directly read from the
specified migrations directory. It, instead, has those migrations embeded into
the application binary. This means that if you delete the specified migrations
folder, the previously built application binary will still have the old
migrations. The only way to update the migrations from the binary is by
rebuilding the application. This is useful so that the application will
automatically apply any needed migration when it is deployed to production.

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
