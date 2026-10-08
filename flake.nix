{
  description = "Apache CloudStack management server for NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      # The Maven dependency hash has only been verified on x86_64-linux.
      systems = [ "x86_64-linux" ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      overlays.default = final: _prev: {
        cloudstackPackages = final.callPackage ./pkgs/cloudstack { };
        inherit (final.cloudstackPackages) cloudstack-management;
      };

      packages = forAllSystems (
        pkgs:
        let
          cloudstack = pkgs.callPackage ./pkgs/cloudstack { };
        in
        {
          inherit (cloudstack) cloudstack-build cloudstack-ui cloudstack-management;
          default = cloudstack.cloudstack-management;
        }
      );

      # Works with or without the overlay: without it, the module builds the
      # package from this flake's expressions with the system's nixpkgs.
      nixosModules = {
        cloudstack-management = ./nixos/modules/cloudstack-management.nix;
        default = self.nixosModules.cloudstack-management;
      };

      checks = forAllSystems (pkgs: {
        inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) cloudstack-management;
        nixos-management = pkgs.testers.runNixOSTest (import ./tests/management.nix { inherit self; });
        nixos-simulator = pkgs.testers.runNixOSTest (import ./tests/simulator.nix { inherit self; });
      });

      # For working on the upstream source tree.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.jdk17
            pkgs.maven
            pkgs.nodejs_22
            pkgs.python3
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
