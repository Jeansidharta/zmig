{
  inputs = {
    utils.url = "github:numtide/flake-utils";
    zig-flake.url = "github:mitchellh/zig-overlay";

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
      zig-flake,
      zig-cli,
      zig-sqlite,
    }:
    utils.lib.eachDefaultSystem (
      system:
      let
        project_name = "zig-mig";
        project_version = "0.0.1";

        pkgs = nixpkgs.legacyPackages.${system};
        zig = zig-flake.outputs.packages.${system}.master;
        mkLibsLinkScript = ''
          rm -rf libs/
          mkdir -p libs
          ln -s ${zig-cli} libs/zig-cli
          ln -s ${zig-sqlite} libs/zig-sqlite
        '';
        package = pkgs.stdenv.mkDerivation {
          pname = project_name;
          version = project_version;
          src = ./.;
          buildInputs = [
            zig
            pkgs.which
          ];

          buildPhase = ''
            # cd $TEMP
            # cp --no-preserve=mode $src/* . -r
            ${mkLibsLinkScript}

            zig build \
              --prefix $out \
              --release=fast \
              -Doptimize=ReleaseFast \
              -Ddynamic-linker=$(cat $NIX_BINTOOLS/nix-support/dynamic-linker) \
              --cache-dir $TEMP/cache \
              --global-cache-dir $TEMP/global \
              --summary all \
              --color off
          '';
          meta = {
            mainProgram = "zmig";
          };
        };
      in
      {
        packages.default = package;
        devShell = pkgs.mkShell {
          shellHook = mkLibsLinkScript;
          buildInputs = [
            zig
            pkgs.sqlite.dev
            pkgs.gdb
          ];
        };
      }
    );
}
