# A KVM host. Add it to a KVM cluster from the web UI or with `addHost`: URL
# http://192.0.2.21, user root. Set the global setting `host` to the address
# that agents and system VMs reach the management server at first.
{
  networking.hostName = "kvm1";

  services.cloudstack.agent = {
    enable = true;
    # VNC ports of the VMs, for the console proxy, and live migration.
    openFirewall = true;
  };

  # The bridge that the zone's traffic labels name (cloudbr0 by default),
  # with the host's address.
  networking.bridges.cloudbr0.interfaces = [ "eno1" ];
  networking.interfaces.cloudbr0.ipv4.addresses = [
    {
      address = "192.0.2.21";
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = "192.0.2.1";
  networking.nameservers = [ "192.0.2.1" ];

  # The management server sets the host up over SSH, with its own key.
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    # /var/lib/cloudstack/management/.ssh/id_rsa.pub on the management server.
    "ssh-rsa AAAA... cloud@management"
  ];

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
