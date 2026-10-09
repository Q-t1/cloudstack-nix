# Assembles the management server from the Maven staging tree, the web UI and
# the shared scripts, in a layout close to the upstream packages:
#
#   bin/cloudstack-management       launcher, see cloudstack-management.sh
#   share/cloudstack-management/    jars, webapp, base SQL schema, defaults
#   share/cloudstack-common/        link to the cloudstack-common package
#
# This derivation is cheap: changing it does not rebuild the Java code.
{
  lib,
  stdenvNoCC,
  runtimeShell,
  jre,
  cloudstackSource,
  cloudstack-build,
  cloudstack-common,
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
    mkdir -p "$mgmt"

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

    # The simulator hypervisor plugin. The launcher leaves it off the
    # classpath unless CLOUDSTACK_EXTRA_CLASSPATH adds it; its schema and seed
    # data are in setup/ (create-schema-simulator.sql, *.simulator.sql).
    install -Dm644 "$build/plugins/hypervisors/simulator/target/cloud-plugin-hypervisor-simulator-${version}.jar" \
      -t "$mgmt/simulator"

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
      --replace-fail /usr/share/cloudstack-common "$out/share/cloudstack-common"
    # The config means to send warnings to a local syslog over UDP, but Log4j 2
    # defaults to TCP port 4560: every warning then logs an appender error.
    substituteInPlace "$mgmt/conf/log4j-cloud.xml" \
      --replace-fail '<Syslog name="SYSLOG" host="localhost" facility="LOCAL6">' \
                     '<Syslog name="SYSLOG" host="localhost" port="514" protocol="UDP" facility="LOCAL6">'

    # Scripts and system VM patch files, where the launcher and
    # environment.properties (paths.script) expect them.
    ln -s ${cloudstack-common}/share/cloudstack-common "$out/share/cloudstack-common"

    # Interpreters come from PATH, as for the scripts in cloudstack-common.
    find "$mgmt/extensions" -type f -exec sed -i -E \
      '1s@^#![[:space:]]*/(usr/)?bin/(bash|python3)[[:space:]]*$@#!/usr/bin/env \2@' {} +

    install -Dm644 tools/whisker/LICENSE tools/whisker/NOTICE \
      -t "$out/share/doc/cloudstack-management"

    # The launcher runs what upstream's systemd unit runs, from its
    # environment file, with this package's paths.
    source ${./upstream-default.sh}
    readUpstreamDefault packaging/systemd/cloudstack-management.default BOOTSTRAP_CLASS
    javaOpts=$(mapUpstreamOptions "$upstreamJavaOpts" \
      '/etc/cloudstack/management/=$conf_dir/')
    classpath=$(mapUpstreamClasspath "$upstreamClasspath" \
      "/usr/share/cloudstack-management/lib/*=$mgmt/lib/*" \
      '/etc/cloudstack/management=$conf_dir' \
      "/usr/share/cloudstack-common=$out/share/cloudstack-common" \
      "/usr/share/cloudstack-management/setup=$mgmt/setup" \
      "/usr/share/cloudstack-management=$mgmt" \
      "/usr/share/cloudstack-mysql-ha/lib/*=")
    mkdir -p "$out/bin"
    substitute ${./cloudstack-management.sh} "$out/bin/cloudstack-management" \
      --subst-var-by shell ${runtimeShell} \
      --subst-var-by jre ${jre} \
      --subst-var out \
      --subst-var-by upstreamJavaOpts "$javaOpts" \
      --subst-var-by upstreamClasspath "$classpath" \
      --subst-var-by upstreamMainClass "$upstreamMainClass"
    chmod +x "$out/bin/cloudstack-management"

    runHook postInstall
  '';

  # Script shebangs are handled above and must not become store paths.
  dontPatchShebangs = true;
  dontStrip = true;

  passthru = {
    inherit
      jre
      cloudstack-build
      cloudstack-common
      cloudstack-ui
      ;
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
