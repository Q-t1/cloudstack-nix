# The management server: the API and web UI (http://192.0.2.10:8080/client,
# admin / password at first), with its database and the usage server.
{
  networking.hostName = "management";

  services.cloudstack.management = {
    enable = true;
    # The address that other management servers use to reach this one.
    nodeAddress = "192.0.2.10";
    # The web UI and API (8080), the port that agents and system VMs connect
    # to (8250) and the cluster port of the management servers (9090).
    openFirewall = true;
    usage.enable = true;
  };

  networking.interfaces.eno1.ipv4.addresses = [
    {
      address = "192.0.2.10";
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = "192.0.2.1";
  networking.nameservers = [ "192.0.2.1" ];

  services.openssh.enable = true;

  # Replace with the machine's hardware configuration (nixos-generate-config).
  nixpkgs.hostPlatform = "x86_64-linux";
  boot.loader.systemd-boot.enable = true;
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  # The NixOS release this machine was installed with.
  system.stateVersion = "26.05";
}
