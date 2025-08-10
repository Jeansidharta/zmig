{
  inputs = {
    utils.url = "github:numtide/flake-utils";
    zon-parser.url = "github:Jeansidharta/nix-zon-parser";

    sqlite-amalgamation = {
      url = "https://sqlite.org/2025/sqlite-amalgamation-3480000.zip";
      flake = false;
    };

    zig-cli = {
      url = "github:sam701/zig-cli";
      flake = false;
    };
    zig-sqlite = {
      url = "github:vrischmann/zig-sqlite";
      flake = false;
    };
  };
  outputs =
    {
      self,
      nixpkgs,
      utils,
      zon-parser,
      zig-cli,
      zig-sqlite,
      sqlite-amalgamation,
    }:
    utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zon = zon-parser.parser (builtins.readFile ./build.zig.zon);

        project_name = zon.name;
        version = zon.version;
        deps = pkgs.linkFarm (project_name + "-deps") {
          ${zon.dependencies.sqlite.hash} = zig-sqlite;
          ${zon.dependencies.cli.hash} = zig-cli;
          "1220972595d70da33d69d519392742482cb9762935cecb99924e31f3898d2a330861" = sqlite-amalgamation;
        };

        mkLibsLinkScript = ''
          rm --force libs
          ln -s ${deps} libs
        '';
        package = pkgs.stdenv.mkDerivation {
          pname = project_name;
          version = version;
          src = ./.;
          buildInputs = [
            pkgs.zig
          ];

          meta = {
            mainProgram = "zmig";
          };

          buildPhase = ''
            # cp --no-preserve=mode $src/* . -r
            # ${mkLibsLinkScript}

            zig build \
              --system ${deps} \
              --prefix $out \
              --release=safe \
              -Doptimize=ReleaseSafe \
              -Ddynamic-linker=$(cat $NIX_BINTOOLS/nix-support/dynamic-linker) \
              --cache-dir cache \
              --global-cache-dir global \
              --summary all
          '';
        };
      in
      {
        packages.default = package;
        devShell = pkgs.mkShell {
          shellHook = mkLibsLinkScript;
          buildInputs = [
            pkgs.zig
            pkgs.zls
          ];
        };
      }
    )
    // {
      lib = ./.;
    };
}
