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

  outputs = inputs@{
    flake-parts,
    nixpkgs,
    systems,
    zig-overlay,
    zls,
    ...
  }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import systems;

      perSystem =
        { system, ... }:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ zig-overlay.overlays.default ];
          };

          zig = pkgs.zigpkgs.master;
        in
        {
          devShells.default = pkgs.mkShell {
            packages = [
              zig
              zls.packages.${system}.default
            ];
          };
        };
    };
}
