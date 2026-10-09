# Assembles the usage server from the Maven staging tree, in a layout close to
# the upstream package:
#
#   bin/cloudstack-usage            launcher, see cloudstack-usage.sh
#   share/cloudstack-usage/lib/     jars
#   share/cloudstack-usage/conf/    default db.properties and log4j-cloud.xml
#
# This derivation is cheap: changing it does not rebuild the Java code.
{
  lib,
  stdenvNoCC,
  runtimeShell,
  jre,
  cloudstackSource,
  cloudstack-build,
}:

let
  inherit (cloudstackSource) version;
in
stdenvNoCC.mkDerivation {
  pname = "cloudstack-usage";
  inherit version;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    target=${cloudstack-build}/usage/target
    usage=$out/share/cloudstack-usage

    # The dependencies include the MySQL driver, which upstream copies from
    # the management server's jars as well.
    install -Dm644 "$target/cloud-usage-${version}.jar" "$usage/lib/cloudstack-usage.jar"
    install -m644 "$target"/dependencies/*.jar "$usage/lib/"

    # Upstream installs these in /etc/cloudstack/usage, and replaces
    # db.properties with a link to the management server's.
    install -Dm644 "$target/transformed/db.properties" -t "$usage/conf"
    install -Dm644 "$target/transformed/log4j-cloud_usage.xml" "$usage/conf/log4j-cloud.xml"

    # The launcher runs what upstream's systemd unit runs, from its
    # environment file, with this package's paths.
    source ${./upstream-default.sh}
    readUpstreamDefault ${cloudstackSource.src}/packaging/systemd/cloudstack-usage.default JAVA_CLASS
    javaOpts=$(mapUpstreamOptions "$upstreamJavaOpts")
    classpath=$(mapUpstreamClasspath "$upstreamClasspath" \
      "/usr/share/cloudstack-usage/*=$usage/*" \
      "/usr/share/cloudstack-usage/lib/*=$usage/lib/*" \
      "/usr/share/cloudstack-mysql-ha/lib/*=" \
      '/etc/cloudstack/usage=$conf_dir')
    mkdir -p "$out/bin"
    substitute ${./cloudstack-usage.sh} "$out/bin/cloudstack-usage" \
      --subst-var-by shell ${runtimeShell} \
      --subst-var-by jre ${jre} \
      --subst-var-by upstreamJavaOpts "$javaOpts" \
      --subst-var-by upstreamClasspath "$classpath" \
      --subst-var-by upstreamMainClass "$upstreamMainClass"
    chmod +x "$out/bin/cloudstack-usage"

    runHook postInstall
  '';

  dontStrip = true;

  passthru = {
    inherit jre cloudstack-build;
  };

  meta = {
    description = "Apache CloudStack usage server";
    longDescription = ''
      The usage server turns the usage events that the CloudStack management
      server records (VMs, volumes, IP addresses, network traffic, ...) into
      usage records, which the listUsageRecords API returns, for billing.
    '';
    homepage = "https://cloudstack.apache.org/";
    changelog = "https://github.com/apache/cloudstack/releases/tag/${version}";
    license = lib.licenses.asl20;
    mainProgram = "cloudstack-usage";
    platforms = [ "x86_64-linux" ];
  };
}
