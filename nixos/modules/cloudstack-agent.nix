{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.cloudstack.agent;
  libvirtd = config.virtualisation.libvirtd;

  propertiesFormat = pkgs.formats.javaProperties { };

  # The management server's host setup over SSH writes into confDir and runs
  # scripts from commonLink by these paths, so neither is configurable.
  stateDir = "/var/lib/cloudstack/agent";
  confDir = "/etc/cloudstack/agent";
  commonLink = "/usr/share/cloudstack-common";
  logDir = "/var/log/cloudstack/agent";
  tmpDir = "${stateDir}/tmp";
  # libvirt's PKI directory: under its sysconfdir, which is /var/lib on NixOS,
  # not /etc as keystore-cert-import expects.
  pkiDir = "/var/lib/pki";

  share = "${cfg.package}/share";

  # Tools the agent and its scripts call.
  runtimePackages = [
    # cloudstack-setup-agent, which keystore-cert-import also runs.
    cfg.package
    # keytool, for the agent keystore.
    cfg.package.jre
    # virsh.
    libvirtd.package
    # qemu-img and qemu-nbd.
    libvirtd.qemu.package
    config.systemd.package
    (pkgs.python3.withPackages (ps: [ ps.libvirt ]))
  ]
  ++ (with pkgs; [
    bash
    bzip2
    cdrkit
    coreutils
    # Volume encryption.
    cryptsetup
    curl
    diffutils
    ethtool
    findutils
    gawk
    gnugrep
    gnused
    gnutar
    gzip
    iproute2
    ipset
    iptables
    iputils
    kmod
    lvm2
    nettools
    nfs-utils
    openssh
    openssl
    # lspci, for GPU discovery.
    pciutils
    procps
    psmisc
    unzip
    util-linux
    wget
    which
    xz
  ])
  ++ cfg.extraPackages;

  # The package's cloudstack-common, with the two scripts that the management
  # server runs over SSH wrapped to get the tools above: they would otherwise
  # get the SSH session's PATH, which has no keytool.
  common =
    pkgs.runCommand "cloudstack-agent-common-${cfg.package.version}"
      {
        nativeBuildInputs = [
          pkgs.lndir
          pkgs.makeWrapper
        ];
      }
      ''
        mkdir "$out"
        lndir -silent ${share}/cloudstack-common "$out"
        for script in keystore-setup keystore-cert-import; do
          rm "$out/scripts/util/$script"
          makeWrapper ${share}/cloudstack-common/scripts/util/$script "$out/scripts/util/$script" \
            --prefix PATH : ${lib.makeBinPath runtimePackages}
        done
      '';

  # Upstream's file from the package, with the entries of `settings` in place
  # of its entries with the same keys.
  layeredProperties =
    file: settings:
    pkgs.runCommand "cloudstack-agent-${file}" { } ''
      ${pkgs.gawk}/bin/awk -f ${./merge-properties.awk} \
        ${propertiesFormat.generate file settings} ${share}/cloudstack-agent/conf/${file} > "$out"
    '';

  settingsOption =
    file: extraDescription:
    lib.mkOption {
      type = lib.types.submodule { freeformType = propertiesFormat.type; };
      default = { };
      description = ''
        Entries of {file}`${file}`, in place of the entries of upstream's file
        with the same keys. ${extraDescription}
      '';
    };

  # The agent exits right away without a guid, i.e. until the host is added
  # to a cluster (or configured here). It is skipped until then rather than
  # restarted every few seconds; cloudstack-setup-agent starts it.
  hasGuid = pkgs.writeShellScript "cloudstack-agent-has-guid" ''
    ${pkgs.gnugrep}/bin/grep -q '^[[:space:]]*guid[[:space:]]*[=:][[:space:]]*[^[:space:]]' \
      ${confDir}/agent.properties 2>/dev/null
  '';
in
{
  options.services.cloudstack.agent = {
    enable = lib.mkEnableOption ''
      the Apache CloudStack KVM agent. The management server sets up the host
      over SSH when it is added to a cluster: it needs to log in as root, or
      as a user allowed to run `sudo` without a password. The host also needs
      the bridges named in the zone's traffic labels (by default `cloudbr0`),
      which this module does not create
    '';

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.cloudstack-agent or (pkgs.callPackage ../../pkgs/cloudstack { }).cloudstack-agent;
      defaultText = lib.literalExpression "pkgs.cloudstack-agent";
      description = "The CloudStack agent package.";
    };

    settings = {
      agent = settingsOption "agent.properties" ''
        The agent keeps its state in this file too, and the management server
        writes the host's zone, pod, cluster, guid and network devices there
        when it adds the host. So the file is kept across restarts: it starts
        as upstream's default, and at each start the entries set here replace
        the ones with the same keys. Entries removed from here stay in the
        file.
      '';
      uefi = settingsOption "uefi.properties" ''
        The defaults replace upstream's Debian firmware paths with the UEFI
        firmware shipped with QEMU.
      '';
      environment = settingsOption "environment.properties" ''
        The default points `paths.script` at the scripts that the management
        server's host setup runs.
      '';
    };

    javaOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "-Xmx4g" ];
      description = ''
        Extra JVM options. They come after upstream's (its
        {file}`packaging/systemd/cloudstack-agent.default`), so they override
        them. They are word-split, so they cannot contain spaces.
      '';
    };

    logConfig = lib.mkOption {
      type = lib.types.path;
      default = "${share}/cloudstack-agent/conf/log4j-cloud.xml";
      defaultText = lib.literalExpression ''"''${cfg.package}/share/cloudstack-agent/conf/log4j-cloud.xml"'';
      description = ''
        Log4j 2 configuration. The default logs to {file}`${logDir}/agent.log`.
      '';
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.ceph ]";
      description = ''
        Extra packages in the agent's PATH, e.g. for storage plugins or
        rolling maintenance hooks.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open the VNC ports of the VMs (5900-6100), which the console proxy
        connects to, and the ports for live migration: libvirtd's TLS port
        (16514) and QEMU's migration ports (49152-49215).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.security.sudo.enable || config.security.sudo-rs.enable;
        message = "services.cloudstack.agent needs sudo (security.sudo or security.sudo-rs): the management server runs its setup scripts with it, even as root.";
      }
    ];

    warnings = lib.optional (!config.services.openssh.enable) ''
      services.cloudstack.agent: the management server adds KVM hosts over SSH, but services.openssh is disabled.
    '';

    services.cloudstack.agent.settings = {
      uefi = lib.mapAttrs (_: lib.mkDefault) {
        # Stable links to the firmware of libvirtd's QEMU. The secure boot
        # firmware has no keys enrolled.
        "guest.loader.legacy" = "/run/libvirt/nix-ovmf/edk2-x86_64-code.fd";
        "guest.nvram.template.legacy" = "/run/libvirt/nix-ovmf/edk2-i386-vars.fd";
        "guest.loader.secure" = "/run/libvirt/nix-ovmf/edk2-x86_64-secure-code.fd";
        "guest.nvram.template.secure" = "/run/libvirt/nix-ovmf/edk2-i386-vars.fd";
        "guest.nvram.path" = "/var/lib/libvirt/qemu/nvram/";
      };
      environment = lib.mapAttrs (_: lib.mkDefault) {
        "paths.script" = commonLink;
      };
    };

    virtualisation.libvirtd = {
      enable = true;
      # Upstream's host setup sets these. namespaces = [] is the default
      # here, which any definition replaces.
      qemu.verbatimConfig = ''
        namespaces = []
        security_driver = "none"
        vnc_listen = "0.0.0.0"
      '';
      hooks.qemu.cloudstack = "${share}/cloudstack-agent/lib/libvirtqemuhook";
    };

    # libvirtd mounts NFS storage pools itself, with the mount in its PATH.
    systemd.services.libvirtd.path = [
      pkgs.util-linux
      pkgs.nfs-utils
    ];

    # The keystore scripts take libvirtd.conf as the sign that they run on a
    # KVM host rather than in a system VM (where keystore-cert-import would
    # wait forever), and read the QEMU group from qemu.conf. libvirtd itself
    # gets its configuration from the store, see virtualisation.libvirtd.
    environment.etc."libvirt/libvirtd.conf".text = ''
      # Not read by libvirtd, see virtualisation.libvirtd.extraConfig.
      # CloudStack's keystore scripts check that this file exists.
    '';
    environment.etc."libvirt/qemu.conf".source = "/var/lib/libvirt/qemu.conf";

    environment.etc."cloudstack/agent".source = stateDir;

    # The management server's SSH client (trilead-ssh2) has none of the
    # encrypt-then-MAC algorithms, the only ones NixOS allows by default, and
    # cannot log in otherwise. Add the SHA-2 ones it offers to the defaults;
    # an explicit Macs setting replaces both.
    services.openssh.settings.Macs = lib.mkIf config.services.openssh.enableRecommendedAlgorithms (
      lib.mkOptionDefault [
        "hmac-sha2-512"
        "hmac-sha2-256"
      ]
    );

    # The bridge firewall used by security groups, and VLAN interfaces for
    # guest networks.
    boot.kernelModules = [
      "br_netfilter"
      "8021q"
    ];

    # Primary and secondary storage are usually NFS.
    boot.supportedFilesystems.nfs = true;

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [ 16514 ];
      allowedTCPPortRanges = [
        {
          from = 5900;
          to = 6100;
        }
        {
          from = 49152;
          to = 49215;
        }
      ];
    };

    # libvirtd's TLS socket, for live migration: the agent connects to the
    # destination's libvirtd with qemu+tls once the host is secured. libvirtd
    # cannot start without its certificate, so the socket waits for the one
    # that the management server issues when it adds the host; then
    # keystore-cert-import runs `cloudstack-setup-agent -s`, which starts it.
    systemd.sockets.libvirtd-tls = {
      wantedBy = [ "sockets.target" ];
      unitConfig.ConditionPathExists = "${stateDir}/cloud.crt";
    };

    # cloudstack-setup-agent, which the management server runs over SSH, and
    # upstream's helpers.
    environment.systemPackages = [ cfg.package ];

    systemd.tmpfiles.rules = [
      # The keystore scripts that the management server runs before the
      # agent's first start record the keystore passphrase in this file.
      "d ${stateDir} 0700 root root - -"
      "C ${stateDir}/agent.properties - - - - ${share}/cloudstack-agent/conf/agent.properties"
      "z ${stateDir}/agent.properties 0600 root root - -"
      "d /usr/share 0755 root root - -"
      "L+ ${commonLink} - - - - ${common}"
      # The agent logs commands here when command reconciliation is enabled.
      "d /usr/share/cloudstack-agent 0755 root root - -"
      "L+ /usr/share/cloudstack-agent/tmp - - - - ${tmpDir}"
      # The default local.storage.path, for host-local primary storage.
      "d /var/lib/libvirt/images 0711 root root - -"
      # The host's certificate, for libvirtd's TLS socket and for the
      # agent's connections to other hosts' libvirtd.
      "d ${pkiDir}/libvirt/private 0700 root root - -"
      "L+ ${pkiDir}/CA/cacert.pem - - - - ${stateDir}/cloud.ca.crt"
      "L+ ${pkiDir}/libvirt/servercert.pem - - - - ${stateDir}/cloud.crt"
      "L+ ${pkiDir}/libvirt/clientcert.pem - - - - ${stateDir}/cloud.crt"
      "L+ ${pkiDir}/libvirt/private/serverkey.pem - - - - ${stateDir}/cloud.key"
      "L+ ${pkiDir}/libvirt/private/clientkey.pem - - - - ${stateDir}/cloud.key"
    ];

    systemd.services.cloudstack-agent = {
      description = "Apache CloudStack KVM agent";
      wantedBy = [ "multi-user.target" ];
      requires = [ "libvirtd.service" ];
      after = [
        "network-online.target"
        "libvirtd.service"
      ];
      wants = [ "network-online.target" ];

      # The agent runs some commands through sudo, even as root.
      path = runtimePackages ++ [ "/run/wrappers" ];

      environment = {
        CLOUDSTACK_CONF_DIR = confDir;
        JAVA_OPTS = lib.concatStringsSep " " cfg.javaOptions;
      };

      # Applies the declared entries to agent.properties and links the other
      # configuration files next to it.
      preStart = ''
        set -euo pipefail
        umask 0077

        props=${confDir}/agent.properties

        # Declared entries replace the file's entries with the same keys, or
        # are appended. The file is replaced atomically, as the setup scripts
        # do.
        awk -f ${./merge-properties.awk} \
          ${propertiesFormat.generate "agent.properties" cfg.settings.agent} "$props" \
          > ${confDir}/.agent.properties.new
        chmod --reference="$props" ${confDir}/.agent.properties.new
        mv ${confDir}/.agent.properties.new "$props"

        ln -sfn ${layeredProperties "environment.properties" cfg.settings.environment} ${confDir}/environment.properties
        ln -sfn ${layeredProperties "uefi.properties" cfg.settings.uefi} ${confDir}/uefi.properties
        ln -sfn ${cfg.logConfig} ${confDir}/log4j-cloud.xml

        mkdir -p ${tmpDir}
      '';

      serviceConfig = {
        ExecCondition = lib.mkIf (!cfg.settings.agent ? guid) hasGuid;
        ExecStart = lib.getExe cfg.package;
        Restart = "always";
        RestartSec = "10s";
        LogsDirectory = "cloudstack/agent";
        LogsDirectoryMode = "0750";
        # The JVM exits with 143 on SIGTERM.
        SuccessExitStatus = 143;
      };
    };
  };
}
