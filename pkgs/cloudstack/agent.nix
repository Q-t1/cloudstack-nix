# Assembles the KVM agent from the Maven staging tree, in a layout close to the
# upstream packages:
#
#   bin/cloudstack-agent          launcher, see cloudstack-agent.sh
#   bin/cloudstack-setup-agent    run by the management server when it adds
#                                 the host, see cloudstack-setup-agent.sh
#   bin/cloudstack-ssh            SSH into a system VM running on this host
#   bin/cloudstack-guest-tool     queries the QEMU guest agent of a VM
#   share/cloudstack-agent/lib/   jars, libvirt qemu hook, rolling maintenance
#   share/cloudstack-agent/conf/  default configuration files
#   share/cloudstack-common/      link to the cloudstack-common package
#
# This derivation is cheap: changing it does not rebuild the Java code.
{
  lib,
  stdenvNoCC,
  runtimeShell,
  coreutils,
  gawk,
  libvirt,
  python3,
  jre,
  cloudstackSource,
  cloudstack-build,
  cloudstack-common,
}:

let
  inherit (cloudstackSource) version src;
  common = "${cloudstack-common}/share/cloudstack-common";
  # The guest tool uses the libvirt bindings; the hook only needs cloudutils.
  pythonWithLibvirt = python3.withPackages (ps: [ ps.libvirt ]);
in
stdenvNoCC.mkDerivation {
  pname = "cloudstack-agent";
  inherit version src;

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    build=${cloudstack-build}
    transformed=$build/agent/target/transformed
    agent=$out/share/cloudstack-agent

    # The KVM plugin and its dependencies (the agent among them), plus the
    # storage plugins that upstream ships with the agent.
    install -Dm644 -t "$agent/lib" \
      "$build/plugins/hypervisors/kvm/target/cloud-plugin-hypervisor-kvm-${version}.jar" \
      "$build"/plugins/hypervisors/kvm/target/dependencies/*.jar \
      "$build/plugins/storage/volume/storpool/target/cloud-plugin-storage-volume-storpool-${version}.jar" \
      "$build/plugins/storage/volume/linstor/target/cloud-plugin-storage-volume-linstor-${version}.jar"

    # libvirt runs the hook on VM events: it rewrites the bridge names of
    # incoming migrations and runs the scripts in /etc/libvirt/hooks/custom.
    # The rolling maintenance systemd units run the other script. Both run on
    # this host only, so they get store interpreters.
    install -Dm755 -t "$agent/lib" \
      "$transformed/libvirtqemuhook" "$transformed/rolling-maintenance"
    substituteInPlace "$agent/lib/libvirtqemuhook" \
      --replace-fail '#!/usr/bin/python3' '#!${lib.getExe python3}' \
      --replace-fail '"/usr/lib/python3/site-packages/"' '"${common}/python-site"'
    substituteInPlace "$agent/lib/rolling-maintenance" \
      --replace-fail '#!/usr/bin/python3' '#!${lib.getExe python3}'

    # Defaults for the configuration directory. paths.script tells the agent
    # where the scripts are.
    install -Dm644 -t "$agent/conf" \
      "$transformed/agent.properties" \
      "$transformed/environment.properties" \
      "$transformed/log4j-cloud.xml" \
      "$transformed/uefi.properties"
    substituteInPlace "$agent/conf/environment.properties" \
      --replace-fail /usr/share/cloudstack-common "$out/share/cloudstack-common"

    ln -s ${common} "$out/share/cloudstack-common"

    # The launcher runs what upstream's systemd unit runs, from its
    # environment file, with this package's paths. Plugins go in
    # CLOUDSTACK_EXTRA_CLASSPATH.
    source ${./upstream-default.sh}
    readUpstreamDefault packaging/systemd/cloudstack-agent.default JAVA_CLASS
    javaOpts=$(mapUpstreamOptions "$upstreamJavaOpts" \
      /usr/share/cloudstack-agent/tmp=/usr/share/cloudstack-agent/tmp)
    classpath=$(mapUpstreamClasspath "$upstreamClasspath" \
      "/usr/share/cloudstack-agent/lib/*=$agent/lib/*" \
      "/usr/share/cloudstack-agent/plugins/*=" \
      '/etc/cloudstack/agent=$conf_dir' \
      "/usr/share/cloudstack-common/scripts=$out/share/cloudstack-common/scripts")
    mkdir -p "$out/bin"
    substitute ${./cloudstack-agent.sh} "$out/bin/cloudstack-agent" \
      --subst-var-by shell ${runtimeShell} \
      --subst-var-by jre ${jre} \
      --subst-var-by libvirt ${lib.getLib libvirt} \
      --subst-var-by upstreamJavaOpts "$javaOpts" \
      --subst-var-by upstreamClasspath "$classpath" \
      --subst-var-by upstreamMainClass "$upstreamMainClass"
    substitute ${./cloudstack-setup-agent.sh} "$out/bin/cloudstack-setup-agent" \
      --subst-var-by shell ${runtimeShell} \
      --subst-var-by path ${
        lib.makeBinPath [
          coreutils
          gawk
        ]
      }
    install -Dm755 "$transformed/cloud-ssh" "$out/bin/cloudstack-ssh"
    substituteInPlace "$out/bin/cloudstack-ssh" \
      --replace-fail '#!/bin/bash' '#!${runtimeShell}'
    install -Dm755 "$transformed/cloud-guest-tool" "$out/bin/cloudstack-guest-tool"
    substituteInPlace "$out/bin/cloudstack-guest-tool" \
      --replace-fail '#!/usr/bin/env python3' '#!${lib.getExe pythonWithLibvirt}'
    chmod +x "$out/bin/cloudstack-agent" "$out/bin/cloudstack-setup-agent"

    install -Dm644 tools/whisker/LICENSE tools/whisker/NOTICE \
      -t "$out/share/doc/cloudstack-agent"

    runHook postInstall
  '';

  # Interpreters are set above.
  dontPatchShebangs = true;
  dontStrip = true;

  passthru = {
    inherit
      jre
      libvirt
      cloudstack-build
      cloudstack-common
      ;
  };

  meta = {
    description = "Apache CloudStack KVM agent";
    longDescription = ''
      The agent runs on KVM hosts. It connects to the CloudStack management
      server and manages VMs, networks and storage on the host through
      libvirt.
    '';
    homepage = "https://cloudstack.apache.org/";
    changelog = "https://github.com/apache/cloudstack/releases/tag/${version}";
    license = lib.licenses.asl20;
    mainProgram = "cloudstack-agent";
    platforms = [ "x86_64-linux" ];
  };
}
