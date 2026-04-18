{
  description = "zmath Zig development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    systems.url = "github:nix-systems/default";

    zig-flake = {
      url = "github:silversquirl/zig-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zls = {
      url = "github:zigtools/zls/0.16.0";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.zig-flake.follows = "zig-flake";
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
            zig = inputs'.zig-flake.packages.zig_0_16_0;
            raylibBuildInputs = [
              pkgs.libGL
              pkgs.libx11
              pkgs.libxcursor
              pkgs.libxext
              pkgs.libxfixes
              pkgs.libxi
              pkgs.libxinerama
              pkgs.libxrandr
              pkgs.libxrender
            ];
            raylibLibraryPath = lib.makeLibraryPath raylibBuildInputs;
            raylibIncludePath = lib.makeSearchPathOutput "dev" "include" raylibBuildInputs;
            raylibPkgConfigPath = lib.makeSearchPathOutput "dev" "lib/pkgconfig" raylibBuildInputs;
          in
          {
            devShells.default = pkgs.mkShell {
              packages = [
                zig
                inputs'.zls.packages.default
                pkgs.pkg-config
              ];
              buildInputs = raylibBuildInputs;

              env = {
                PKG_CONFIG_PATH = raylibPkgConfigPath;
                C_INCLUDE_PATH = raylibIncludePath;
                LIBRARY_PATH = raylibLibraryPath;
                LD_LIBRARY_PATH = raylibLibraryPath;
              };
            };
          };
      }
    );
}
