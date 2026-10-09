# Upstream files that this flake follows by hand, with their hashes as last
# reviewed, and what to review when one changes. checks.upstream-files fails
# when a CloudStack bump changes one of them; after the review, update its
# sha256 here and `reviewed`.
#
# Not listed: what is built from upstream's files directly (the launchers from
# packaging/systemd/*.default, the .properties files layered on upstream's)
# and what the build patches with `substituteInPlace --replace-fail`, which
# fail on their own when upstream changes. The check also compares upstream's
# sudo commands with sudo-commands.nix, and the system VM template version
# with source.nix.
{
  reviewed = "4.23.0.0";

  files = {
    "setup/bindir/cloud-setup-databases.in" = {
      sha256 = "f13ad1ca20f772a542697d740eb80fe2df424616e40734d4ae6612ae3829ffed";
      review = ''
        nixos/modules/cloudstack-management.nix: cloudstack-management-init
        (databases, user and grants, the base schema scripts it loads), and
        the db.properties entries settings.db sets as it does.
      '';
    };
    "setup/db/create-database.sql" = {
      sha256 = "3b162ffa5adff1c671be223a95d352668e01258a8cdfc77f75bc401697c106bf";
      review = "cloudstack-management-init: the cloud database, its user and grants.";
    };
    "setup/db/create-database-premium.sql" = {
      sha256 = "3cee068a9e0729f068ab8efdd1a3b49e7cb75c207b9ba50e14f736fedd990c26";
      review = "cloudstack-management-init: the cloud_usage database and its grants.";
    };
    "agent/bindir/cloud-setup-agent.in" = {
      sha256 = "8a79dfbbe7578fa3d68151cbfe4d4869e06a4288d9afdcd9311cd3044591abd9";
      review = ''
        pkgs/cloudstack/cloudstack-setup-agent.sh, which replaces it: its
        options, the agent.properties entries it writes, what -s does.
      '';
    };
    "python/lib/cloudutils/serviceConfig.py" = {
      sha256 = "8b0f328a96764302eed34b9a63ca65676ce28c27d10fea71c332d99b28d5826a";
      review = ''
        What upstream's host setup configures, which NixOS does instead:
        nixos/modules/cloudstack-agent.nix (libvirtd and qemu.conf, TLS,
        kernel modules), cloudstack-setup-agent.sh, and the README's KVM host
        section (bridges, firewall).
      '';
    };
    "scripts/util/keystore-setup" = {
      sha256 = "de7718eb1d95ef4eac3f320531584b78a5663b62d1662745b7919ff9b07a1450";
      review = "nixos/modules/cloudstack-agent.nix: the tools in its wrapper's PATH.";
    };
    "scripts/util/keystore-cert-import" = {
      sha256 = "7cec050d6260cc6a8c41481789a1ad17110ebea6e7386edeabb942effe4b13f7";
      review = ''
        nixos/modules/cloudstack-agent.nix: the tools in its wrapper's PATH,
        the /var/lib/pki links (it links /etc/pki), the libvirtd.conf marker,
        and `cloudstack-setup-agent -s`.
      '';
    };
    "packaging/systemd/cloudstack-management.service" = {
      sha256 = "5ddd02e0a6b9ac6217422a43805f4e87659188a374c6405349392fde0f94676a";
      review = ''
        systemd.services.cloudstack-management (user, dependencies, restart
        policy, limits) and the java command in cloudstack-management.sh.
      '';
    };
    "packaging/systemd/cloudstack-agent.service" = {
      sha256 = "c1a651ff30f3e49cea9e12d11b85a89cf7848b64e2b3af6c94323f56f41c657b";
      review = "systemd.services.cloudstack-agent and the java command in cloudstack-agent.sh.";
    };
    "packaging/systemd/cloudstack-usage.service" = {
      sha256 = "792e27aff85f5457f07deaa2903df0a420290aae86c2033c8b519b1fd03250cd";
      review = "systemd.services.cloudstack-usage and the java command in cloudstack-usage.sh.";
    };
    "packaging/systemd/cloudstack-rolling-maintenance@.service" = {
      sha256 = "048f819bffb0850ed90552ca0fc1704e83d82dc312566d90df459d6b6694972a";
      review = ''
        Not shipped as a unit: agent.nix only installs the script it runs.
      '';
    };
    "debian/rules" = {
      sha256 = "fde8c23f2d1bd940d5d3a9d90ae5f05a070b1057a55082ebf4e018fed7456043";
      review = ''
        The install layouts in pkgs/cloudstack/{common,management,agent,usage}.nix
        and the artifacts that build.nix keeps.
      '';
    };
    "debian/cloudstack-common.install" = {
      sha256 = "832b66d32c4ca06c86ca1cd47715960452dea281fc65b063ba6147f925c2bbb9";
      review = "pkgs/cloudstack/common.nix.";
    };
    "debian/cloudstack-management.install" = {
      sha256 = "36b113fc40f7a43c49b66dbae71fca89484c2225c54283bf3c0744cc323aa532";
      review = "pkgs/cloudstack/management.nix.";
    };
    "debian/cloudstack-ui.install" = {
      sha256 = "01c2cbb67d281d10faf6dd16e106bb47a5343f4fb697187cd9be00e0ba95a656";
      review = "pkgs/cloudstack/ui.nix and the webapp in management.nix.";
    };
    "debian/cloudstack-agent.install" = {
      sha256 = "f30ae1dd0191af29527d7ebfcabee3e555abad96ff01892e46930b1420878849";
      review = "pkgs/cloudstack/agent.nix.";
    };
    "debian/cloudstack-agent.dirs" = {
      sha256 = "623462e79f6c24384c15f8270e29d95372e0c90407dd82c6f6e3b412d0f7e880";
      review = "The directories nixos/modules/cloudstack-agent.nix creates.";
    };
    "debian/cloudstack-usage.install" = {
      sha256 = "899a92a9e48b27434828504866f9590012d575122dba0163a493e36480b08782";
      review = "pkgs/cloudstack/usage.nix.";
    };
    "debian/cloudstack-usage.dirs" = {
      sha256 = "f36274be1a2b5d7f40aa3a8f9356725a894c2eadcf414c9008604293e434af9f";
      review = "The directories the usage server's unit gets (cloudstack-management.nix).";
    };
    "debian/cloudstack-common.postinst" = {
      sha256 = "6b9df4ae0ec8e6723124ed1230955ff8dfbaa04213fb132a584ff185075e6df3";
      review = "What the modules set up for the scripts in cloudstack-common.";
    };
    "debian/cloudstack-management.preinst" = {
      sha256 = "920f7598f564c87e178ecde4cab0016f8c1fcca3d9ad0f8cd3fa0c00d8927a9b";
      review = "nixos/modules/cloudstack-management.nix (upgrades of existing installations).";
    };
    "debian/cloudstack-management.postinst" = {
      sha256 = "f06f10407d1da4d6458f80a798c83f9a386be57ea8a0ee239113271e2bea1518";
      review = ''
        nixos/modules/cloudstack-management.nix: the cloud user, directories,
        permissions, links and generated files.
      '';
    };
    "debian/cloudstack-agent.postinst" = {
      sha256 = "2b771e8dfbc3f145963d3c6b0f4437f1a3216828f9e98d4126ab49a8b209fe16";
      review = "nixos/modules/cloudstack-agent.nix: directories, links and generated files.";
    };
    "debian/cloudstack-usage.preinst" = {
      sha256 = "aabda7265b3b32b7542664eed3f716de651593b14a04dc451f7f2d4efb661abc";
      review = "The usage server's unit in nixos/modules/cloudstack-management.nix.";
    };
    "debian/cloudstack-usage.postinst" = {
      sha256 = "1fa6957c05f7992a9c96c547c9dccc5900f3f57f24205e36330554a85c396ce1";
      review = ''
        The usage server's unit in nixos/modules/cloudstack-management.nix:
        the shared db.properties and key, the sanity check's state file.
      '';
    };
  };
}
