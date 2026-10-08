# Assembles the management server from the Maven staging tree, the web UI and
# the shared scripts, in a layout close to the upstream packages:
#
#   bin/cloudstack-management       launcher, see cloudstack-management.sh
#   share/cloudstack-management/    jars, webapp, base SQL schema, defaults
#   share/cloudstack-common/        scripts and system VM patch files
#
# This derivation is cheap: changing it does not rebuild the Java code.
{
  lib,
  stdenvNoCC,
  runtimeShell,
  jre,
  cloudstackSource,
  cloudstack-build,
  cloudstack-ui,
}:

let
  inherit (cloudstackSource) version src;
in
stdenvNoCC.mkDerivation {
  pname = "cloudstack-management";
  inherit version src;

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    build=${cloudstack-build}
    mgmt=$out/share/cloudstack-management
    common=$out/share/cloudstack-common
    mkdir -p "$mgmt" "$common"

    # The shaded client jar, plus the jars upstream keeps out of it.
    install -Dm644 "$build/client/target/cloud-client-ui-${version}.jar" \
      "$mgmt/lib/cloudstack-${version}.jar"
    install -m644 "$build"/client/target/lib/*.jar "$mgmt/lib/"

    # Jetty serves the UI from here (server.properties: webapp.dir).
    cp -r "$build/client/target/classes/META-INF/webapp" "$mgmt/webapp"
    chmod -R u+w "$mgmt/webapp"
    cp -r ${cloudstack-ui}/. "$mgmt/webapp/"

    # Base SQL schema (CloudStack 4.0), loaded once before the first start;
    # the management server upgrades it to the current version itself.
    cp -r "$build/client/target/utilities/scripts/db" "$mgmt/setup"

    # System VM template metadata. The templates themselves are downloaded on
    # demand when a zone gets its secondary storage.
    install -Dm644 "$build/engine/schema/dist/systemvm-templates/metadata.ini" \
      -t "$mgmt/templates/systemvm"

    # CloudStack Kubernetes Service node configuration templates.
    mkdir -p "$mgmt/cks"
    cp -r plugins/integrations/kubernetes-service/src/main/resources/conf "$mgmt/cks/conf"

    # Sample extensions, seeded into the writable extensions directory.
    cp -r extensions "$mgmt/extensions"

    # Default configuration files.
    cp -r "$build/client/target/conf" "$mgmt/conf"
    chmod -R u+w "$mgmt/conf"
    ln -s log4j-cloud.xml "$mgmt/conf/log4j2.xml"
    substituteInPlace "$mgmt/conf/server.properties" \
      --replace-fail /usr/share/cloudstack-management "$mgmt"
    substituteInPlace "$mgmt/conf/environment.properties" \
      --replace-fail /usr/share/cloudstack-common "$common"
    # The config means to send warnings to a local syslog over UDP, but Log4j 2
    # defaults to TCP port 4560: every warning then logs an appender error.
    substituteInPlace "$mgmt/conf/log4j-cloud.xml" \
      --replace-fail '<Syslog name="SYSLOG" host="localhost" facility="LOCAL6">' \
                     '<Syslog name="SYSLOG" host="localhost" port="514" protocol="UDP" facility="LOCAL6">'

    # Shared scripts and system VM patch files ("cloudstack-common").
    cp -r scripts "$common/scripts"
    cp -r "$build/systemvm/dist" "$common/vms"
    install -Dm644 "$build"/client/target/pythonlibs/jasypt-*.jar -t "$common/lib"
    install -Dm644 "$build/utils/target/cloud-utils-${version}-bundled.jar" \
      "$common/lib/cloudstack-utils.jar"
    substituteInPlace "$common/scripts/storage/secondary/cloud-install-sys-tmplt" \
      --replace-fail /usr/share/cloudstack-common "$common"

    # Resolve interpreters from PATH instead of FHS paths. Not store paths:
    # some scripts are copied to XenServer/OVM3 hosts, and on NixOS the
    # service PATH decides which tools they get.
    find "$common/scripts" "$mgmt/extensions" -type f -exec sed -i -E \
      '1s@^#![[:space:]]*/(usr/)?bin/(bash|python3)[[:space:]]*$@#!/usr/bin/env \2@' {} +

    # injectkeys.sh copies the system VM private key over this file (upstream
    # ships a publicly known placeholder key there), and the Hyper-V and
    # baremetal code reads it back. Point it at the key the management server
    # keeps in its home directory instead: injectkeys.sh then finds identical
    # files and has nothing to write into the store.
    ln -sf /var/lib/cloudstack/management/.ssh/id_rsa \
      "$common/scripts/vm/systemvm/id_rsa.cloud"

    install -Dm644 tools/whisker/LICENSE tools/whisker/NOTICE \
      -t "$out/share/doc/cloudstack-management"

    mkdir -p "$out/bin"
    substitute ${./cloudstack-management.sh} "$out/bin/cloudstack-management" \
      --subst-var-by shell ${runtimeShell} \
      --subst-var-by jre ${jre} \
      --subst-var out
    chmod +x "$out/bin/cloudstack-management"

    runHook postInstall
  '';

  # Script shebangs are handled above and must not become store paths.
  dontPatchShebangs = true;
  dontStrip = true;
  # id_rsa.cloud points into /var/lib.
  dontCheckForBrokenSymlinks = true;

  passthru = {
    inherit jre cloudstack-build cloudstack-ui;
  };

  meta = {
    description = "Apache CloudStack management server";
    longDescription = ''
      Apache CloudStack is an IaaS cloud orchestration platform. The
      management server provides the API and web UI and orchestrates the
      hypervisor hosts, storage and system VMs.
    '';
    homepage = "https://cloudstack.apache.org/";
    changelog = "https://github.com/apache/cloudstack/releases/tag/${version}";
    license = lib.licenses.asl20;
    mainProgram = "cloudstack-management";
    platforms = [ "x86_64-linux" ];
  };
}
