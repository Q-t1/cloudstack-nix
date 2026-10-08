# Package scope, so the whole set can be overridden consistently, e.g.
#   cloudstackPackages.overrideScope (final: prev: { jre = pkgs.jdk21_headless; })
{
  lib,
  newScope,
  jdk17_headless,
}:

lib.makeScope newScope (self: {
  cloudstackSource = self.callPackage ./source.nix { };

  # Runtime Java for the management server. Upstream supports 17 and 21 and
  # recommends 17. A full JDK rather than a JRE: the server also runs keytool.
  # (Defined here because callPackage would otherwise inject pkgs.jre.)
  jre = jdk17_headless;

  cloudstack-build = self.callPackage ./build.nix { };
  cloudstack-ui = self.callPackage ./ui.nix { };
  cloudstack-management = self.callPackage ./management.nix { };
})
