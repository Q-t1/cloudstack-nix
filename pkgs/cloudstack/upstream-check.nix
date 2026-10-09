# checks.upstream-files: fails when a CloudStack bump changes what this flake
# follows by hand (see upstream-files.nix), and says what to review. It only
# needs the source, not the Maven build.
{
  lib,
  runCommand,
  callPackage,
  jre,
  cloudstackSource,
}:

let
  inherit (cloudstackSource) src version systemvmTemplateVersion;
  upstream = import ./upstream-files.nix;
  sudo = callPackage ./sudo-commands.nix { inherit jre; };
in
runCommand "cloudstack-upstream-files-${version}" { } ''
  failed=0
  report() {
    if [ "$failed" -eq 0 ]; then
      echo "CloudStack ${version} changed what this flake follows by hand, last reviewed for ${upstream.reviewed}:"
      echo "  https://github.com/apache/cloudstack/compare/${upstream.reviewed}...${version}"
    fi
    failed=1
    echo
    printf '%s\n' "$@"
  }

  check_file() {
    local path=$1 expected=$2 review=$3 actual
    if [ ! -f "${src}/$path" ]; then
      report "$path: removed upstream." "  Review: $review"
      return
    fi
    actual=$(sha256sum "${src}/$path" | cut -d' ' -f1)
    if [ "$actual" != "$expected" ]; then
      report "$path: changed." "  Review: $review" \
        "  Then set its sha256 in pkgs/cloudstack/upstream-files.nix to $actual."
    fi
  }
  ${lib.concatStrings (
    lib.mapAttrsToList (path: file: ''
      check_file ${lib.escapeShellArg path} ${file.sha256} ${lib.escapeShellArg (lib.concatStringsSep " " (lib.splitString "\n" (lib.trim file.review)))}
    '') upstream.files
  )}

  # The commands that the management server may run through sudo.
  upstream_sudo=$(sed -n 's/^Cmnd_Alias CLOUDSTACK *= *//p' ${src}/server/conf/cloudstack-sudoers.in |
    tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort)
  ours_sudo=$(printf '%s\n' ${lib.escapeShellArgs (lib.attrNames sudo.commands)} | sort)
  if [ -z "$upstream_sudo" ]; then
    report "server/conf/cloudstack-sudoers.in: no Cmnd_Alias CLOUDSTACK any more." \
      "  Review the sudo rule in nixos/modules/cloudstack-management.nix."
  elif [ "$upstream_sudo" != "$ours_sudo" ]; then
    report "server/conf/cloudstack-sudoers.in: the sudo commands changed:" \
      "$(diff <(echo "$ours_sudo") <(echo "$upstream_sudo") |
        sed -n 's/^< /  only in sudo-commands.nix: /p; s/^> /  only upstream: /p')" \
      "  Update pkgs/cloudstack/sudo-commands.nix."
  fi

  # The system VM templates that the management server expects.
  pom_version=$(sed -n 's|.*<project.systemvm.template.version>\(.*\)</project.systemvm.template.version>.*|\1|p' \
    ${src}/pom.xml | head -n 1)
  if [ "$(echo "$pom_version" | cut -d. -f1-3)" != ${systemvmTemplateVersion} ]; then
    report "pom.xml: project.systemvm.template.version is $pom_version, but source.nix has ${systemvmTemplateVersion}." \
      "  Update systemvmTemplateVersion, the checksum file and systemvmTemplates in source.nix."
  fi

  if [ "$failed" -ne 0 ]; then
    echo
    echo "After the review, update pkgs/cloudstack/upstream-files.nix, and its 'reviewed'."
    exit 1
  fi
  touch "$out"
''
