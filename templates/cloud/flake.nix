{
  description = "A CloudStack cloud on NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Without `inputs.nixpkgs.follows`, the CloudStack packages are the ones
    # that cloudstack-nix builds and tests, with its own nixpkgs.
    cloudstack-nix.url = "github:Q-t1/cloudstack-nix";
  };

  outputs =
    { nixpkgs, cloudstack-nix, ... }:
    let
      machine =
        file:
        nixpkgs.lib.nixosSystem {
          modules = [
            cloudstack-nix.nixosModules.default
            file
          ];
        };
    in
    {
      nixosConfigurations = {
        management = machine ./management.nix;
        kvm1 = machine ./kvm-host.nix;
      };
    };
}
