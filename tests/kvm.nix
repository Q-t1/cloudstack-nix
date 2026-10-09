# Deploys an advanced zone on a KVM host: the management server sets the host
# up over SSH (certificates, then cloudstack-setup-agent) and the agent
# connects back; with NFS primary and secondary storage, the zone then starts
# its system VMs on the host. The KVM host is itself a VM, so this needs
# nested virtualisation on the machine running the test.
{ self }:
{
  name = "cloudstack-kvm";

  nodes = {
    management =
      { pkgs, ... }:
      {
        imports = [ self.nixosModules.cloudstack-management ];

        virtualisation = {
          cores = 2;
          memorySize = 4096;
          diskSize = 4096;
        };

        services.cloudstack.management = {
          enable = true;
          openFirewall = true;
          # The test has no network access to download it.
          systemVmTemplates = [
            self.packages.${pkgs.stdenv.hostPlatform.system}.cloudstack-systemvm-template-kvm
          ];
        };

        environment.systemPackages = [ pkgs.jq ];
      };

    kvm =
      { config, lib, ... }:
      {
        imports = [ self.nixosModules.cloudstack-agent ];

        # Room for the system VMs: the secondary storage VM and the console
        # proxy take 1.5 GB.
        virtualisation = {
          cores = 4;
          memorySize = 6144;
          diskSize = 4096;
        };

        # The test network goes into the bridge that the zone's traffic
        # labels name, and the host address with it.
        networking.bridges.cloudbr0.interfaces = [ "eth1" ];
        networking.interfaces.eth1 = {
          ipv4.addresses = lib.mkForce [ ];
          ipv6.addresses = lib.mkForce [ ];
        };
        networking.interfaces.cloudbr0.ipv4.addresses = [
          {
            address = config.networking.primaryIPAddress;
            prefixLength = 24;
          }
        ];

        # The management server logs in as root with a password.
        services.openssh = {
          enable = true;
          settings.PermitRootLogin = "yes";
        };
        users.users.root = {
          # The test framework's empty password would take precedence.
          hashedPasswordFile = lib.mkForce null;
          password = "password";
        };

        services.cloudstack.agent.enable = true;
      };

    nfs = {
      virtualisation.diskSize = 8192;

      services.nfs.server = {
        enable = true;
        createMountPoints = true;
        exports = ''
          /export/primary 192.168.1.0/24(rw,no_root_squash,no_subtree_check)
          /export/secondary 192.168.1.0/24(rw,no_root_squash,no_subtree_check)
        '';
      };
      # NFSv3 clients also need rpcbind and mountd, on changing ports.
      networking.firewall.enable = false;
    };
  };

  testScript =
    { nodes, ... }:
    let
      managementIP = nodes.management.networking.primaryIPAddress;
      kvmIP = nodes.kvm.networking.primaryIPAddress;
      nfsIP = nodes.nfs.networking.primaryIPAddress;
    in
    ''
      import json
      import shlex
      from contextlib import contextmanager
      from datetime import timedelta

      api = "http://localhost:8080/client/api"

      @contextmanager
      def logs_on_failure():
          try:
              yield
          except Exception:
              print(management.execute("tail -n 300 /var/log/cloudstack/management/management-server.log")[1])
              print(kvm.execute("tail -n 200 /var/log/cloudstack/agent/agent.log")[1])
              print(kvm.execute("journalctl -n 100 --no-pager -u cloudstack-agent -u sshd -u libvirtd")[1])
              print(kvm.execute("virsh list --all; ip -br address")[1])
              raise

      # CloudMonkey's defaults (admin/password on localhost:8080) match the
      # server's. Async APIs block until their job ends.
      def cmk_command(*args, **params):
          assignments = [f"{key}={value}" for key, value in params.items()]
          return shlex.join(["cloudstack-cloudmonkey", "-o", "json", *args, *assignments])

      def cmk(*args, **params):
          output = management.succeed(cmk_command(*args, **params), timeout=timedelta(minutes=10))
          return json.loads(output) if output.strip() else {}

      def wait_for(jq_filter, *args, timeout=timedelta(minutes=10), **params):
          management.wait_until_succeeds(
              f"{cmk_command(*args, **params)} | jq -e {shlex.quote(jq_filter)}",
              timeout=timeout,
          )

      start_all()

      with subtest("the KVM host waits to be added"):
          kvm.wait_for_unit("multi-user.target")
          kvm.succeed("test -c /dev/kvm")
          kvm.wait_for_unit("libvirtd.service")
          kvm.succeed("grep -qx 'guid=' /etc/cloudstack/agent/agent.properties")
          kvm.succeed("test -x /usr/share/cloudstack-common/scripts/util/keystore-setup")
          # Skipped by its condition, not restarted over and over.
          kvm.succeed("systemctl show -P ActiveState cloudstack-agent | grep -qx inactive")
          kvm.succeed("systemctl show -P NRestarts cloudstack-agent | grep -qx 0")

      with subtest("the management server comes up"), logs_on_failure():
          management.wait_for_unit("cloudstack-management.service")
          management.wait_until_succeeds(
              f"curl -s -o /dev/null -w '%{{http_code}}' '{api}?command=listCapabilities&response=json' | grep -qx 401",
              timeout=timedelta(minutes=30),
          )
          management.succeed("cloudstack-cloudmonkey sync")
          # Agents and system VMs connect to this address. It defaults to the
          # address of the default route, the test VM's NAT interface.
          cmk("update", "configuration", name="host", value="${managementIP}")

      with subtest("a KVM host is added and comes up"), logs_on_failure():
          zone = cmk(
              "create", "zone",
              name="kvm", networktype="Advanced", guestcidraddress="10.1.1.0/24",
              dns1="${managementIP}", internaldns1="${managementIP}",
          )["zone"]
          pnet = cmk(
              "create", "physicalnetwork",
              zoneid=zone["id"], name="pnet", isolationmethods="VLAN", vlan="100-200",
          )["physicalnetwork"]
          for traffic in ["Guest", "Management", "Public"]:
              cmk("add", "traffictype", physicalnetworkid=pnet["id"], traffictype=traffic, kvmnetworklabel="cloudbr0")
          cmk("update", "physicalnetwork", id=pnet["id"], state="Enabled")

          provider = cmk(
              "list", "networkserviceproviders", name="VirtualRouter", physicalnetworkid=pnet["id"]
          )["networkserviceprovider"][0]
          element = cmk("list", "virtualrouterelements", nspid=provider["id"])["virtualrouterelement"][0]
          cmk("configure", "virtualrouterelement", id=element["id"], enabled="true")
          cmk("update", "networkserviceprovider", id=provider["id"], state="Enabled")

          # Public addresses for the system VMs, on the same bridge.
          cmk(
              "create", "vlaniprange",
              zoneid=zone["id"], vlan="untagged", forvirtualnetwork="true",
              gateway="192.168.2.1", netmask="255.255.255.0", startip="192.168.2.10", endip="192.168.2.20",
          )
          pod = cmk(
              "create", "pod",
              zoneid=zone["id"], name="pod",
              gateway="192.168.1.254", netmask="255.255.255.0", startip="192.168.1.100", endip="192.168.1.150",
          )["pod"]
          cluster = cmk(
              "add", "cluster",
              zoneid=zone["id"], podid=pod["id"], clustername="kvm",
              hypervisor="KVM", clustertype="CloudManaged",
          )["cluster"][0]
          cmk(
              "add", "host",
              zoneid=zone["id"], podid=pod["id"], clusterid=cluster["id"], hypervisor="KVM",
              url="http://${kvmIP}", username="root", password="password",
          )
          wait_for('.count == 1 and .host[0].state == "Up"', "list", "hosts", type="Routing", zoneid=zone["id"])

      with subtest("the agent is set up and secured"), logs_on_failure():
          kvm.succeed("systemctl is-active cloudstack-agent.service")
          # The management server passes its internal (numeric) ids.
          for entry in ["zone=[0-9]+", "pod=[0-9]+", "cluster=[0-9]+", "guid=.+", "guest.network.device=cloudbr0"]:
              kvm.succeed(f"grep -qxE '{entry}' /etc/cloudstack/agent/agent.properties")
          kvm.succeed("grep -q '^host=${managementIP}' /etc/cloudstack/agent/agent.properties")
          kvm.succeed("grep -q '^keystore.passphrase=.' /etc/cloudstack/agent/agent.properties")
          kvm.succeed("test -s /etc/cloudstack/agent/cloud.jks -a -s /etc/cloudstack/agent/cloud.crt")
          host = cmk("list", "hosts", type="Routing", zoneid=zone["id"])["host"][0]
          assert host["hypervisor"] == "KVM", f"unexpected hypervisor {host['hypervisor']}"
          assert host["ipaddress"] == "${kvmIP}", f"unexpected host address {host['ipaddress']}"

      with subtest("the agent reconnects after a restart"), logs_on_failure():
          def connections():
              return int(kvm.succeed("grep -c 'connected to the server' /var/log/cloudstack/agent/agent.log || true"))

          def placement():
              return kvm.succeed("grep -E '^(zone|pod|cluster|guid)=' /etc/cloudstack/agent/agent.properties")

          before = connections()
          placed = placement()
          kvm.systemctl("restart cloudstack-agent.service")
          kvm.wait_until_succeeds(f"[ $(grep -c 'connected to the server' /var/log/cloudstack/agent/agent.log) -gt {before} ]", timeout=timedelta(minutes=5))
          wait_for('.host[0].state == "Up"', "list", "hosts", type="Routing", zoneid=zone["id"])
          assert placement() == placed, "the restart changed the host's placement"

      with subtest("NFS storage is added and the system VM template seeded"), logs_on_failure():
          nfs.wait_for_unit("nfs-server.service")
          cmk(
              "create", "storagepool",
              zoneid=zone["id"], podid=pod["id"], clusterid=cluster["id"],
              name="primary", url="nfs://${nfsIP}/export/primary",
          )
          wait_for('.count == 1 and .storagepool[0].state == "Up"', "list", "storagepools", zoneid=zone["id"])
          kvm.succeed("virsh pool-list | grep -q active")
          cmk(
              "add", "imagestore",
              zoneid=zone["id"], provider="NFS",
              name="secondary", url="nfs://${nfsIP}/export/secondary",
          )
          # Seeded from systemVmTemplates: the test has no network access.
          nfs.wait_until_succeeds("find /export/secondary/template -name template.properties | grep -q .", timeout=600)

      with subtest("the zone is enabled and its system VMs run on the KVM host"), logs_on_failure():
          cmk("update", "zone", id=zone["id"], allocationstate="Enabled")
          wait_for(
              '.count == 2 and all(.systemvm[]; .state == "Running")',
              "list", "systemvms", zoneid=zone["id"],
              timeout=timedelta(minutes=30),
          )
          wait_for(
              '.count == 1 and .host[0].state == "Up"',
              "list", "hosts", type="SecondaryStorageVM", zoneid=zone["id"],
              timeout=timedelta(minutes=15),
          )
          for vm in cmk("list", "systemvms", zoneid=zone["id"])["systemvm"]:
              kvm.succeed(f"virsh domstate {vm['name']} | grep -qx running")
    '';
}
