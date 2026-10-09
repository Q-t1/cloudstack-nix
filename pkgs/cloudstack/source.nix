# Pinned upstream inputs shared by every CloudStack derivation.
# Bumping CloudStack means updating this file, then the dependency hashes in
# build.nix (mvnHash) and ui.nix (npmDepsHash).
{ fetchFromGitHub, fetchurl }:

rec {
  version = "4.23.0.0";

  src = fetchFromGitHub {
    owner = "apache";
    repo = "cloudstack";
    tag = version;
    hash = "sha256-Svzm7Ux+/OGqk4pza3PXgNQTCWUWgRkoeAmEGtqWC+M=";
  };

  # `project.systemvm.template.version` from the root pom.xml. It lags behind the
  # CloudStack version: 4.23 still ships the 4.22.0 system VM templates.
  systemvmTemplateVersion = "4.22.0";

  # engine/schema downloads this file during the Maven `validate` phase and
  # derives templates/systemvm/metadata.ini from it. Prefetched for the sandbox.
  systemvmTemplateChecksums = fetchurl {
    url = "https://download.cloudstack.org/systemvm/4.22/sha512sum.txt";
    hash = "sha256-2gL6yo/Pplld4W3SDR5xOGgfz/s3Eqkn4w4qsOvHLG0=";
  };

  # System VM templates, for services.cloudstack.management.systemVmTemplates.
  # The management server copies them to new secondary storage, and downloads
  # the ones it lacks. The checksums are in systemvmTemplateChecksums.
  systemvmTemplates = {
    kvm-x86_64 = fetchurl {
      url = "https://download.cloudstack.org/systemvm/4.22/systemvmtemplate-${systemvmTemplateVersion}-x86_64-kvm.qcow2.bz2";
      sha512 = "10987c4fb3158d40006b1a1db89bf6e9b6c3995294f295e1ca564c26c9543453d4d21a7d8c967d5487b489d88194ecfba9829f00e929b17e3ddaa70751cece90";
    };
  };
}
