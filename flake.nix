{
  description = "Apache CloudStack on NixOS: management server, KVM agent and usage server, built from source and tested in VMs";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      # The Maven dependency hash has only been verified on x86_64-linux.
      systems = [ "x86_64-linux" ];
      forAllSystems =
        f:
        lib.genAttrs systems (
          system:
          f {
            inherit system;
            pkgs = nixpkgs.legacyPackages.${system};
            cloudstack = self.legacyPackages.${system}.cloudstackPackages;
          }
        );

      # This flake's package `name`, as the default of a module option. Not
      # when the system's nixpkgs has the overlay, or when this flake has no
      # packages for the system: the module's own default applies then.
      packageDefault =
        pkgs: name:
        let
          packages = self.packages.${pkgs.stdenv.hostPlatform.system} or { };
        in
        lib.mkIf (!pkgs ? ${name} && packages ? ${name}) (lib.mkDefault packages.${name});
    in
    {
      overlays.default = final: _prev: {
        cloudstackPackages = final.callPackage ./pkgs/cloudstack { };
        inherit (final.cloudstackPackages) cloudstack-management cloudstack-agent cloudstack-usage;
      };

      # The package scope, which the other outputs take their packages from.
      # Overriding it changes every package consistently, e.g.
      #   cloudstackPackages.overrideScope (final: prev: { jre = pkgs.jdk21_headless; })
      legacyPackages = forAllSystems (
        { pkgs, ... }:
        {
          cloudstackPackages = pkgs.callPackage ./pkgs/cloudstack { };
        }
      );

      packages = forAllSystems (
        { cloudstack, ... }:
        {
          inherit (cloudstack)
            cloudstack-build
            cloudstack-common
            cloudstack-ui
            cloudstack-management
            cloudstack-agent
            cloudstack-usage
            ;
          cloudstack-systemvm-template-kvm = cloudstack.systemvmTemplates.kvm-x86_64;
          default = cloudstack.cloudstack-management;
        }
      );

      # The modules default to this flake's packages: built with its locked
      # nixpkgs, as its checks build and test them, whatever nixpkgs the
      # system has. With the overlay, they default to the overlay's packages,
      # built with the system's nixpkgs.
      nixosModules = {
        cloudstack-management =
          { pkgs, ... }:
          {
            _class = "nixos";
            # Imported once, also when imported again through `default`.
            key = "cloudstack-nix#nixosModules.cloudstack-management";
            imports = [ ./nixos/modules/cloudstack-management.nix ];
            services.cloudstack.management = {
              package = packageDefault pkgs "cloudstack-management";
              usage.package = packageDefault pkgs "cloudstack-usage";
            };
          };
        cloudstack-agent =
          { pkgs, ... }:
          {
            _class = "nixos";
            key = "cloudstack-nix#nixosModules.cloudstack-agent";
            imports = [ ./nixos/modules/cloudstack-agent.nix ];
            services.cloudstack.agent.package = packageDefault pkgs "cloudstack-agent";
          };
        # Both services, each behind its enable option.
        default = {
          _class = "nixos";
          imports = [
            self.nixosModules.cloudstack-management
            self.nixosModules.cloudstack-agent
          ];
        };
      };

      # `nix run github:Q-t1/cloudstack-nix#demo`, see nixos/demo.
      apps = forAllSystems (
        { system, ... }:
        let
          demo = lib.nixosSystem {
            modules = [
              self.nixosModules.cloudstack-management
              ./nixos/demo/vm.nix
              { nixpkgs.hostPlatform = system; }
            ];
          };
        in
        {
          demo = {
            type = "app";
            program = lib.getExe demo.config.system.build.vm;
            meta.description = "A VM running CloudStack with a zone on the simulator hypervisor, its web UI on localhost:8080";
          };
        }
      );

      templates.default = {
        path = ./templates/cloud;
        description = "A CloudStack cloud: a management server and a KVM host";
        welcomeText = ''
          # A CloudStack cloud on NixOS

          `management.nix` is the management server, `kvm-host.nix` a KVM
          host. Replace their hardware settings and addresses, then
          deploy them, e.g. with `nixos-rebuild switch --flake .#management`.
          See https://github.com/Q-t1/cloudstack-nix for what the modules
          set up and how to add the host to a zone.
        '';
      };

      checks = forAllSystems (
        {
          system,
          pkgs,
          cloudstack,
        }:
        {
          inherit (self.packages.${system})
            cloudstack-management
            cloudstack-agent
            cloudstack-usage
            ;
          # Cheap: only needs the source. See pkgs/cloudstack/upstream-files.nix.
          upstream-files = cloudstack.cloudstack-upstream-files;

          # Cheap: evaluates the template's machines, which catches option
          # changes and failed assertions without building anything.
          template =
            let
              machine =
                file:
                builtins.unsafeDiscardStringContext
                  (lib.nixosSystem {
                    modules = [
                      self.nixosModules.default
                      file
                    ];
                  }).config.system.build.toplevel.drvPath;
            in
            pkgs.writeText "cloudstack-template-machines" ''
              ${machine ./templates/cloud/management.nix}
              ${machine ./templates/cloud/kvm-host.nix}
            '';

          formatting =
            pkgs.runCommand "cloudstack-nix-formatting"
              {
                nativeBuildInputs = [ pkgs.nixfmt ];
                src = lib.fileset.toSource {
                  root = ./.;
                  fileset = lib.fileset.fileFilter (file: file.hasExt "nix") ./.;
                };
              }
              ''
                cd "$src"
                find . -name '*.nix' -exec nixfmt --check {} + || {
                  echo "Run 'nix fmt' to format these files."
                  exit 1
                }
                touch "$out"
              '';

          nixos-management = pkgs.testers.runNixOSTest (import ./tests/management.nix { inherit self; });
          nixos-simulator = pkgs.testers.runNixOSTest (import ./tests/simulator.nix { inherit self; });
          nixos-demo = pkgs.testers.runNixOSTest (import ./tests/demo.nix { inherit self; });
          nixos-kvm = pkgs.testers.runNixOSTest (import ./tests/kvm.nix { inherit self; });
        }
      );

      # For working on the upstream source tree.
      devShells = forAllSystems (
        { pkgs, ... }:
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.jdk17
              pkgs.maven
              pkgs.nodejs_22
              pkgs.python3
            ];
          };
        }
      );

      formatter = forAllSystems ({ pkgs, ... }: pkgs.nixfmt-tree);
    };
}
