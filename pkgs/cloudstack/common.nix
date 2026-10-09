# Files shared by the management server and the KVM agent, like upstream's
# cloudstack-common package:
#
#   share/cloudstack-common/scripts      scripts run locally or copied to hosts
#   share/cloudstack-common/vms          system VM patch files (agent.zip, ...)
#   share/cloudstack-common/lib          jasypt and the bundled utils jar
#   share/cloudstack-common/python-site  the cloudutils Python library
#
# This derivation is cheap: changing it does not rebuild the Java code.
{
  lib,
  stdenvNoCC,
  cloudstackSource,
  cloudstack-build,
}:

let
  inherit (cloudstackSource) version src;
in
stdenvNoCC.mkDerivation {
  pname = "cloudstack-common";
  inherit version src;

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    build=${cloudstack-build}
    common=$out/share/cloudstack-common
    mkdir -p "$common"

    cp -r scripts "$common/scripts"
    cp -r "$build/systemvm/dist" "$common/vms"
    install -Dm644 "$build"/client/target/pythonlibs/jasypt-*.jar -t "$common/lib"
    install -Dm644 "$build/utils/target/cloud-utils-${version}-bundled.jar" \
      "$common/lib/cloudstack-utils.jar"
    install -Dm644 python/lib/cloud_utils.py -t "$common/python-site"
    cp -r python/lib/cloudutils "$common/python-site/cloudutils"

    substituteInPlace "$common/scripts/storage/secondary/cloud-install-sys-tmplt" \
      --replace-fail /usr/share/cloudstack-common "$common"

    # Resolve interpreters from PATH instead of FHS paths. Not store paths:
    # some scripts are copied to XenServer/OVM3 hosts, and on NixOS the
    # service PATH decides which tools they get.
    find "$common/scripts" -type f -exec sed -i -E \
      '1s@^#![[:space:]]*/(usr/)?bin/(bash|python3)[[:space:]]*$@#!/usr/bin/env \2@' {} +

    # injectkeys.sh copies the system VM private key over this file (upstream
    # ships a publicly known placeholder key there), and the Hyper-V and
    # baremetal code reads it back. Point it at the key the management server
    # keeps in its home directory instead: injectkeys.sh then finds identical
    # files and has nothing to write into the store. KVM agents use
    # /root/.ssh/id_rsa.cloud, so on their hosts this link dangles.
    ln -sf /var/lib/cloudstack/management/.ssh/id_rsa \
      "$common/scripts/vm/systemvm/id_rsa.cloud"

    install -Dm644 tools/whisker/LICENSE tools/whisker/NOTICE \
      -t "$out/share/doc/cloudstack-common"

    runHook postInstall
  '';

  # Script shebangs are handled above and must not become store paths.
  dontPatchShebangs = true;
  dontStrip = true;
  # id_rsa.cloud points into /var/lib.
  dontCheckForBrokenSymlinks = true;

  meta = {
    description = "Apache CloudStack scripts and files shared by the management server and the agent";
    homepage = "https://cloudstack.apache.org/";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
  };
}
