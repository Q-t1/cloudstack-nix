# The VM of `nix run .#demo`, with the console in the terminal and the web UI
# forwarded to localhost:8080. Its disk, ./cloudstack-demo.qcow2, keeps the
# database across runs.
{ lib, modulesPath, ... }:

{
  imports = [
    "${modulesPath}/virtualisation/qemu-vm.nix"
    ./.
  ];

  networking.hostName = "cloudstack-demo";
  # The demo's state, the database, does not depend on it: the module sets
  # MariaDB's package.
  system.stateVersion = lib.trivial.release;

  virtualisation = {
    cores = 4;
    memorySize = 4096;
    diskSize = 8192;
    graphics = false;
    # Only on the loopback address: the demo has the default admin password.
    forwardPorts = [
      {
        from = "host";
        host.address = "127.0.0.1";
        host.port = 8080;
        guest.port = 8080;
      }
    ];
  };

  services.getty.autologinUser = "root";
  users.motd = ''

    Welcome to the CloudStack on NixOS demo.

    On the first boot, the management server takes a few minutes to set up
    its database; then cloudstack-demo.service deploys a zone on simulated
    hosts, with a network and a VM:

      journalctl -fu cloudstack-demo    follow the deployment
      cloudstack-cloudmonkey            the CloudStack CLI, logged in as admin

    Web UI: http://localhost:8080/client, user admin, password password.

    `poweroff` stops the VM; delete cloudstack-demo.qcow2 to start over.

  '';
}
