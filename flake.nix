{
  description = "zmath Zig development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    systems.url = "github:nix-systems/default";

    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zls = {
      url = "github:zigtools/zls";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.zig-overlay.follows = "zig-overlay";
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } (
      { lib, ... }:
      {
        systems = import inputs.systems;

        perSystem =
          {
            inputs',
            pkgs,
            system,
            ...
          }:
          let
            zig = pkgs.zigpkgs.master;
            raylibBuildInputs = [
              pkgs.libGL
              pkgs.xorg.libX11
              pkgs.xorg.libXcursor
              pkgs.xorg.libXext
              pkgs.xorg.libXfixes
              pkgs.xorg.libXi
              pkgs.xorg.libXinerama
              pkgs.xorg.libXrandr
              pkgs.xorg.libXrender
            ];
            raylibLibraryPath = lib.makeLibraryPath raylibBuildInputs;
            raylibIncludePath = lib.makeSearchPathOutput "dev" "include" raylibBuildInputs;
            raylibPkgConfigPath = lib.makeSearchPathOutput "dev" "lib/pkgconfig" raylibBuildInputs;
          in
          {
            _module.args.pkgs = import inputs.nixpkgs {
              inherit system;
              overlays = [
                inputs.zig-overlay.overlays.default
              ];
            };

            devShells.default = pkgs.mkShell {
              packages = [
                zig
                inputs'.zls.packages.default
                pkgs.pkg-config
              ];
              buildInputs = raylibBuildInputs;

              PKG_CONFIG_PATH = raylibPkgConfigPath;
              C_INCLUDE_PATH = raylibIncludePath;
              LIBRARY_PATH = raylibLibraryPath;
              LD_LIBRARY_PATH = raylibLibraryPath;
            };
          };
      }
    );
}
