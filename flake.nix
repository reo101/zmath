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
            nativeGraphicsInputs = [
              pkgs.glfw
              pkgs.libGL
              pkgs.libx11
              pkgs.libxcursor
              pkgs.libxext
              pkgs.libxfixes
              pkgs.libxi
              pkgs.libxinerama
              pkgs.libxrandr
              pkgs.libxrender
              pkgs.vulkan-headers
              pkgs.vulkan-loader
            ];
            nativeGraphicsLibraryPath = lib.makeLibraryPath nativeGraphicsInputs;
            nativeGraphicsIncludePath = lib.makeSearchPathOutput "dev" "include" nativeGraphicsInputs;
            nativeGraphicsPkgConfigPath = lib.makeSearchPathOutput "dev" "lib/pkgconfig" nativeGraphicsInputs;
          in
          {
            devShells.default = pkgs.mkShell {
              packages = [
                zig
                inputs'.zls.packages.default
                pkgs.pkg-config
                pkgs.spirv-tools
                pkgs.vulkan-tools
              ];
              buildInputs = nativeGraphicsInputs;

              env = {
                PKG_CONFIG_PATH = nativeGraphicsPkgConfigPath;
                C_INCLUDE_PATH = nativeGraphicsIncludePath;
                LIBRARY_PATH = nativeGraphicsLibraryPath;
                LD_LIBRARY_PATH = nativeGraphicsLibraryPath;
              };
            };
          };
      }
    );
}
