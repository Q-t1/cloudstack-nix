# Package scope, so the whole set can be overridden consistently, e.g.
#   cloudstackPackages.overrideScope (final: prev: { jre = pkgs.jdk21_headless; })
{
  lib,
  newScope,
  jdk17_headless,
}:

lib.makeScope newScope (self: {
  cloudstackSource = self.callPackage ./source.nix { };

  # Runtime Java for the management server and the agent. Upstream supports
  # 17 and 21 and recommends 17. A full JDK rather than a JRE: both also run
  # keytool. (Defined here because callPackage would otherwise inject pkgs.jre.)
  jre = jdk17_headless;

  cloudstack-build = self.callPackage ./build.nix { };
  cloudstack-common = self.callPackage ./common.nix { };
  cloudstack-ui = self.callPackage ./ui.nix { };
  cloudstack-management = self.callPackage ./management.nix { };
  cloudstack-agent = self.callPackage ./agent.nix { };
  cloudstack-usage = self.callPackage ./usage.nix { };

  # Large downloads (hundreds of MB each), only fetched when used.
  inherit (self.cloudstackSource) systemvmTemplates;
})
