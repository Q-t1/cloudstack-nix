# The whole Maven reactor. This is by far the most expensive derivation (the
# dependency FOD and the offline build each compile all ~150 modules), so it
# only compiles and installs a staging tree of build artifacts. Packaging
# derivations (common.nix, management.nix, agent.nix, usage.nix) pick from
# that tree, which keeps layout changes from triggering a Java rebuild.
{
  lib,
  maven,
  jdk17_headless,
  cloudstackSource,
}:

let
  inherit (cloudstackSource) version src systemvmTemplateChecksums;
in
maven.buildMavenPackage {
  pname = "cloudstack-build";
  inherit version src;

  mvnJdk = jdk17_headless;
  mvnHash = "sha256-hU+ifwPZyWMMzDJfRqvKJwjZp8LDFQ0ikm1MxuUzRLg=";

  # Tests are compiled (several modules depend on other modules' test-jars,
  # which rules out -Dmaven.test.skip) but not run: doCheck = false adds
  # -DskipTests.
  doCheck = false;

  # These must stay identical between the dependency FOD and the real build,
  # otherwise the offline build can miss artifacts.
  mvnParameters = lib.escapeShellArgs [
    # Also build systemvm/dist (agent.zip, cloud-scripts.tgz), like upstream.
    "-Psystemvm"
    # engine/schema downloads sha512sum.txt; postPatch provides it instead.
    "-Ddownload.plugin.skip=true"
    "-Dcheckstyle.skip=true"
  ];

  postPatch = ''
    install -Dm644 ${systemvmTemplateChecksums} \
      engine/schema/dist/systemvm-templates/sha512sum.txt

    # Token values substituted into conf templates and helper scripts. Start
    # from the Debian layout (/var/lib/cloudstack/...); packaging derivations
    # rewrite the /usr/share paths to store paths.
    cp packaging/debian/replace.properties build/replace.properties
    echo "VERSION=${version}" >> build/replace.properties

    # NixOS has no /bin/bash. Resolve bash from PATH rather than pinning a store
    # path: these jars also run inside the Debian system VMs (agent.zip).
    grep -rlZ --include='*.java' --exclude-dir=test -F '"/bin/bash"' . \
      | xargs -0 --no-run-if-empty sed -i 's|"/bin/bash"|"bash"|g'

    substituteInPlace engine/storage/configdrive/src/main/java/org/apache/cloudstack/storage/configdrive/ConfigDriveBuilder.java \
      --replace-fail 'getFile("/usr/bin/genisoimage")' \
                     'getFile(Script.getExecutableAbsolutePath("genisoimage"))'

    # Build the simulator hypervisor plugin, for testing, without adding it to
    # the client jar as -Dsimulator does: it replaces the NFS image store
    # provider, so it must stay off the classpath unless asked for.
    substituteInPlace plugins/pom.xml \
      --replace-fail '<module>hypervisors/xenserver</module>' \
                     '<module>hypervisors/xenserver</module><module>hypervisors/simulator</module>'

    substituteInPlace plugins/outofbandmanagement-drivers/ipmitool/src/main/java/org/apache/cloudstack/outofbandmanagement/driver/ipmitool/IpmitoolOutOfBandManagementDriver.java \
      --replace-fail '"/usr/bin/ipmitool"' '"ipmitool"'

    # Install paths baked into the code become system properties (defaulting
    # to the upstream value), so this derivation does not depend on where the
    # files end up. The launcher in management.nix sets them.
    substituteInPlace engine/schema/src/main/java/com/cloud/upgrade/SystemVmTemplateRegistration.java \
      --replace-fail '"/usr/share/cloudstack-management/templates/systemvm/"' \
                     'System.getProperty("cloudstack.systemvm.templates.path", "/usr/share/cloudstack-management/templates/systemvm/")'
    substituteInPlace plugins/integrations/kubernetes-service/src/main/java/com/cloud/kubernetes/cluster/actionworkers/KubernetesClusterActionWorker.java \
      --replace-fail '"/usr/share/cloudstack-management/cks"' \
                     'System.getProperty("cloudstack.cks.config.path", "/usr/share/cloudstack-management/cks")'
    substituteInPlace plugins/hypervisors/external/src/main/java/org/apache/cloudstack/hypervisor/external/provisioner/ExternalPathPayloadProvisioner.java \
      --replace-fail '"/usr/share/cloudstack-management/extensions"' \
                     'System.getProperty("cloudstack.extensions.path", "/usr/share/cloudstack-management/extensions")'
  '';

  installPhase = ''
    runHook preInstall

    # Mirrors the artifacts picked up by packaging/el8/cloud.spec and
    # debian/rules, keeping their source-relative paths.
    mkdir -p "$out"
    keep() {
      for path in "$@"; do
        cp -a --parents "$path" "$out/"
      done
    }
    # Optional extras for future agent/usage packages: tolerate their absence
    # rather than failing at the end of a multi-hour build.
    keepIfPresent() {
      for path in "$@"; do
        if [ -e "$path" ]; then
          cp -a --parents "$path" "$out/"
        else
          echo "warning: $path was not built, skipping" >&2
        fi
      done
    }

    keep \
      client/target/cloud-client-ui-${version}.jar \
      client/target/lib \
      client/target/conf \
      client/target/utilities \
      client/target/pythonlibs \
      client/target/classes/META-INF/webapp \
      server/target/conf \
      utils/target/cloud-utils-${version}-bundled.jar \
      plugins/hypervisors/simulator/target/cloud-plugin-hypervisor-simulator-${version}.jar \
      engine/schema/dist/systemvm-templates \
      systemvm/dist

    keepIfPresent \
      usage/target/cloud-usage-${version}.jar \
      usage/target/dependencies \
      usage/target/transformed \
      agent/target/transformed \
      agent/target/dependencies \
      plugins/hypervisors/kvm/target/cloud-plugin-hypervisor-kvm-${version}.jar \
      plugins/hypervisors/kvm/target/dependencies \
      plugins/storage/volume/storpool/target/cloud-plugin-storage-volume-storpool-${version}.jar \
      plugins/storage/volume/linstor/target/cloud-plugin-storage-volume-linstor-${version}.jar

    runHook postInstall
  '';

  # A raw staging tree: no stripping, shebang patching or symlink checks.
  dontFixup = true;

  meta = {
    description = "Apache CloudStack Maven reactor build (staging tree of artifacts)";
    homepage = "https://cloudstack.apache.org/";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
  };
}
