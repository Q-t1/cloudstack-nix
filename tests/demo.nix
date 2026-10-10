# Boots the machine of `nix run .#demo` (nixos/demo) and waits for its zone on
# the simulator hypervisor, with a network and a VM.
{ self }:
{
  name = "cloudstack-demo";

  nodes.machine = {
    imports = [
      self.nixosModules.cloudstack-management
      ../nixos/demo
    ];

    virtualisation = {
      cores = 4;
      memorySize = 4096;
      diskSize = 4096;
    };
  };

  testScript = ''
    import json
    from datetime import timedelta

    def cmk(*args):
        return json.loads(machine.succeed("cloudstack-cloudmonkey -o json " + " ".join(args)))

    machine.wait_for_unit("cloudstack-management.service")

    with subtest("the demo deploys its zone, a network and a VM"):
        try:
            machine.wait_for_unit("cloudstack-demo.service", timeout=timedelta(minutes=45))
        except Exception:
            print(machine.execute("journalctl -n 100 --no-pager -u cloudstack-demo")[1])
            print(machine.execute("tail -n 300 /var/log/cloudstack/management/management-server.log")[1])
            raise
        zone = cmk("list", "zones", "name=Demo")["zone"][0]
        assert zone["allocationstate"] == "Enabled", f"unexpected zone state {zone['allocationstate']}"
        vm = cmk("list", "virtualmachines", "name=demo-vm")["virtualmachine"][0]
        assert vm["state"] == "Running", f"unexpected VM state {vm['state']}"

    with subtest("the demo leaves an existing zone alone"):
        machine.systemctl("restart cloudstack-demo.service")
        machine.require_unit_state("cloudstack-demo.service", "active")
        machine.succeed("journalctl -u cloudstack-demo | grep -q 'The zone Demo exists already'")
        assert cmk("list", "zones")["count"] == 1
  '';
}
