# Deploys an advanced zone on a KVM host: the management server sets the host
# up over SSH (certificates, then cloudstack-setup-agent) and the agent
# connects back; with NFS primary and secondary storage, the zone then starts
# its system VMs on the host, and a guest VM in an isolated network, which is
# reached through its virtual router, then live-migrated to a second host. The
# KVM hosts are themselves VMs, so this needs nested virtualisation on the
# machine running the test.
{ self }:
let
  kvmHost =
    { config, lib, ... }:
    {
      imports = [ self.nixosModules.cloudstack-agent ];

      virtualisation.diskSize = 4096;

      # The test network goes into the bridge that the zone's traffic labels
      # name, and the host address with it.
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

      services.cloudstack.agent = {
        enable = true;
        # Live migration between the hosts.
        openFirewall = true;
      };
    };
in
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

    kvm = {
      imports = [ kvmHost ];
      # Room for the system VMs: the secondary storage VM and the console
      # proxy take 1.5 GB.
      virtualisation = {
        cores = 4;
        memorySize = 6144;
      };
    };

    # Added once the zone runs, so that it only gets the guest VM, by live
    # migration.
    kvm2 = {
      imports = [ kvmHost ];
      virtualisation = {
        cores = 2;
        memorySize = 3072;
      };
    };

    # Also the public network's gateway, for the guest network's traffic in
    # and out.
    nfs =
      { pkgs, ... }:
      {
        # CloudStack allocates the virtual size of each disk (5 GB per system
        # VM, from the template) against twice the size of the export.
        virtualisation.diskSize = 16384;

        networking.interfaces.eth1.ipv4.addresses = [
          {
            address = "192.168.2.1";
            prefixLength = 24;
          }
        ];
        environment.systemPackages = [ pkgs.sshpass ];

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

        # A guest template, which the secondary storage VM downloads:
        # macchinina, the 20 MB image of upstream's smoke tests. It configures
        # its network with DHCP and gets its root password from the virtual
        # router.
        services.nginx = {
          enable = true;
          virtualHosts.templates = {
            default = true;
            root = pkgs.linkFarm "cloudstack-test-templates" {
              "macchinina-kvm.qcow2.bz2" = pkgs.fetchurl {
                url = "http://dl.openvm.eu/cloudstack/macchinina/x86_64/macchinina-kvm.qcow2.bz2";
                hash = "sha256-vEzAQLurhDAA+reNtstKM/OgauHO0s9WPTazjH/uMEk=";
              };
            };
          };
        };
      };
  };

  testScript =
    { nodes, ... }:
    let
      managementIP = nodes.management.networking.primaryIPAddress;
      kvmIP = nodes.kvm.networking.primaryIPAddress;
      kvm2IP = nodes.kvm2.networking.primaryIPAddress;
      nfsIP = nodes.nfs.networking.primaryIPAddress;
    in
    ''
      import json
      import shlex
      from contextlib import contextmanager
      from datetime import timedelta

      api = "http://localhost:8080/client/api"

      # Into a system VM or virtual router from its host, as the agent does:
      # over its link-local address, with the key that the management server
      # sent to the host.
      def system_vm_ssh(linklocalip):
          return shlex.join([
              "ssh", "-i", "/root/.ssh/id_rsa.cloud", "-p", "3922",
              "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
              "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10",
              f"root@{linklocalip}",
          ])

      @contextmanager
      def logs_on_failure():
          try:
              yield
          except Exception:
              print(management.execute("tail -n 300 /var/log/cloudstack/management/management-server.log")[1])
              for host in [kvm, kvm2]:
                  print(f"--- {host.name}")
                  print(host.execute("tail -n 200 /var/log/cloudstack/agent/agent.log")[1])
                  print(host.execute("journalctl -n 100 --no-pager -u cloudstack-agent -u sshd -u libvirtd")[1])
                  print(host.execute("virsh list --all; ip -br address")[1])
              # The system VMs' agents, which run on the first host.
              status, output = management.execute(cmk_command("list", "systemvms"))
              for systemvm in json.loads(output).get("systemvm", []) if status == 0 and output.strip() else []:
                  if systemvm.get("linklocalip"):
                      print(f"--- {systemvm['name']}")
                      print(kvm.execute(f"{system_vm_ssh(systemvm['linklocalip'])} tail -n 100 /var/log/cloud.log")[1])
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

      # Unauthenticated calls get a 401 once the API is up.
      def wait_for_api():
          management.wait_until_succeeds(
              f"curl -s -o /dev/null -w '%{{http_code}}' '{api}?command=listCapabilities&response=json' | grep -qx 401",
              timeout=timedelta(minutes=30),
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
          # Without the host's certificate, libvirtd does not listen with TLS.
          kvm.succeed("systemctl show -P ActiveState libvirtd-tls.socket | grep -qx inactive")

      with subtest("the management server comes up"), logs_on_failure():
          management.wait_for_unit("cloudstack-management.service")
          wait_for_api()
          management.succeed("cloudstack-cloudmonkey sync")
          # Agents and system VMs connect to this address. It defaults to the
          # address of the default route, the test VM's NAT interface.
          cmk("update", "configuration", name="host", value="${managementIP}")
          # The secondary storage VM only downloads templates from private
          # addresses in these networks, which the server reads when it starts.
          cmk("update", "configuration", name="secstorage.allowed.internal.sites", value="192.168.1.0/24")
          management.systemctl("restart cloudstack-management.service")
          wait_for_api()

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
          # libvirtd listens with TLS, with the host's certificate, which the
          # client side presents too: the agent's check for a secured host.
          kvm.succeed("virsh -c qemu+tls://${kvmIP}/system uri")
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

      with subtest("a template is downloaded from a URL"), logs_on_failure():
          # As upstream's smoke tests register it.
          ostype = cmk("list", "ostypes", description="Other Linux (64-bit)")["ostype"][0]
          template = cmk(
              "register", "template",
              name="macchinina", displaytext="macchinina", url="http://${nfsIP}/macchinina-kvm.qcow2.bz2",
              format="QCOW2", hypervisor="KVM", ostypeid=ostype["id"], zoneid=zone["id"],
              passwordenabled="true",
          )["template"][0]
          wait_for(
              ".template[0].isready",
              "list", "templates", templatefilter="self", id=template["id"],
              timeout=timedelta(minutes=15),
          )

      with subtest("a VM runs in an isolated network on the KVM host"), logs_on_failure():
          network_offering = cmk(
              "list", "networkofferings", name="DefaultIsolatedNetworkOfferingWithSourceNatService"
          )["networkoffering"][0]
          network = cmk(
              "create", "network",
              zoneid=zone["id"], name="guest", displaytext="guest", networkofferingid=network_offering["id"],
          )["network"]
          service_offering = cmk("list", "serviceofferings", name="Small Instance")["serviceoffering"][0]
          vm = cmk(
              "deploy", "virtualmachine",
              zoneid=zone["id"], templateid=template["id"], serviceofferingid=service_offering["id"],
              networkids=network["id"], name="guest",
          )["virtualmachine"]
          assert vm["state"] == "Running", f"unexpected VM state {vm['state']}"
          router = cmk("list", "routers", networkid=network["id"])["router"][0]
          assert router["state"] == "Running", f"unexpected router state {router['state']}"

          kvm.succeed(f"virsh domstate {vm['instancename']} | grep -qx running")
          kvm.succeed(f"virsh domstate {router['name']} | grep -qx running")
          # The agent put the guest network's VLAN on the bridge's interface.
          broadcast_uri = cmk("list", "networks", id=network["id"])["network"][0]["broadcasturi"]
          vlan = broadcast_uri.removeprefix("vlan://")
          kvm.succeed(f"test -d /sys/class/net/breth1-{vlan}/brif/eth1.{vlan}")

      with subtest("the VM gets its address from the virtual router"), logs_on_failure():
          nic = vm["nic"][0]
          router_ssh = system_vm_ssh(router["linklocalip"])
          kvm.wait_until_succeeds(
              f"{router_ssh} grep -q 'DHCPACK.* {nic['ipaddress']} {nic['macaddress']}' /var/log/dnsmasq.log",
              timeout=300,
          )
          # Once the guest has configured it.
          kvm.wait_until_succeeds(f"{router_ssh} ping -c 1 -W 2 {nic['ipaddress']}", timeout=60)

      with subtest("the VM is reachable through port forwarding"), logs_on_failure():
          public_ip = cmk(
              "list", "publicipaddresses", associatednetworkid=network["id"], issourcenat="true"
          )["publicipaddress"][0]
          cmk(
              "create", "portforwardingrule",
              ipaddressid=public_ip["id"], protocol="TCP", publicport="22", privateport="22",
              virtualmachineid=vm["id"],
          )
          # The password that CloudStack generated for the VM, which the guest
          # gets from the virtual router's password server once it has started
          # its SSH server.
          guest_ssh = shlex.join([
              "sshpass", "-p", vm["password"],
              "ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
              f"root@{public_ip['ipaddress']}",
          ])
          nfs.wait_until_succeeds(f"{guest_ssh} true", timeout=300)
          # Its SSH server runs commands with /usr/bin:/bin in PATH.
          nfs.succeed(f"{guest_ssh} /sbin/ip -4 address show eth0 | grep -q 'inet {nic['ipaddress']}/'")
          nfs.succeed(f"{guest_ssh} /sbin/ip route | grep -q '^default via {nic['gateway']} '")

      with subtest("the VM reaches out through source NAT once egress is allowed"), logs_on_failure():
          fetch = f"{guest_ssh} curl -sfI --max-time 10 http://192.168.2.1/macchinina-kvm.qcow2.bz2"
          # The network offering denies egress by default.
          nfs.fail(fetch)
          cmk("create", "egressfirewallrule", networkid=network["id"], protocol="TCP", startport="80", endport="80")
          nfs.succeed(fetch)
          nfs.succeed(f"grep -q '^{public_ip['ipaddress']} .*\"HEAD /macchinina-kvm.qcow2.bz2 ' /var/log/nginx/access.log")

      with subtest("a second KVM host is added to the cluster"), logs_on_failure():
          cmk(
              "add", "host",
              zoneid=zone["id"], podid=pod["id"], clusterid=cluster["id"], hypervisor="KVM",
              url="http://${kvm2IP}", username="root", password="password",
          )
          wait_for('.count == 2 and all(.host[]; .state == "Up")', "list", "hosts", type="Routing", zoneid=zone["id"])
          host2 = next(
              h for h in cmk("list", "hosts", type="Routing", zoneid=zone["id"])["host"]
              if h["ipaddress"] == "${kvm2IP}"
          )
          # Each host's libvirt client gets through to the other's libvirtd.
          kvm.succeed("virsh -c qemu+tls://${kvm2IP}/system uri")
          kvm2.succeed("virsh -c qemu+tls://${kvmIP}/system uri")

      with subtest("the VM is live-migrated to the second host"), logs_on_failure():
          boot_id = nfs.succeed(f"{guest_ssh} cat /proc/sys/kernel/random/boot_id")
          migrated = cmk("migrate", "virtualmachine", virtualmachineid=vm["id"], hostid=host2["id"])["virtualmachine"]
          assert migrated["hostid"] == host2["id"], f"the VM is on host {migrated['hostid']}"
          kvm2.succeed(f"virsh domstate {vm['instancename']} | grep -qx running")
          kvm.fail(f"virsh domstate {vm['instancename']}")
          # Still reachable, through its router on the first host, and still
          # running the same boot.
          assert nfs.succeed(f"{guest_ssh} cat /proc/sys/kernel/random/boot_id") == boot_id, "the VM restarted"

      with subtest("the VM is destroyed and removed from the KVM host"), logs_on_failure():
          cmk("destroy", "virtualmachine", id=vm["id"], expunge="true")
          kvm2.wait_until_fails(f"virsh domstate {vm['instancename']}", timeout=300)
    '';
}
