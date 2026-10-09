# Deploys an advanced zone on the simulator hypervisor, which simulates the
# hosts, storage and system VMs, then a VM in an isolated network, which the
# usage server bills. The zone follows upstream's Marvin configuration
# setup/dev/advanced.cfg.
{ self }:
{
  name = "cloudstack-simulator";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.cloudstack-management ];

      virtualisation = {
        cores = 4;
        memorySize = 4096;
        diskSize = 4096;
      };

      services.cloudstack.management = {
        enable = true;
        simulator.enable = true;
        usage.enable = true;
        # For the web UI through a forwarded port in the interactive driver.
        openFirewall = true;
      };

      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];
    };

  testScript = ''
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
            print(machine.execute("tail -n 300 /var/log/cloudstack/management/management-server.log")[1])
            print(machine.execute("tail -n 100 /var/log/cloudstack/usage/usage.log")[1])
            print(machine.execute("journalctl -n 50 --no-pager -u cloudstack-usage")[1])
            raise

    # CloudMonkey's defaults (admin/password on localhost:8080) match the
    # server's. Async APIs block until their job ends.
    def cmk_command(*args, **params):
        assignments = [f"{key}={value}" for key, value in params.items()]
        return shlex.join(["cloudstack-cloudmonkey", "-o", "json", *args, *assignments])

    def cmk(*args, **params):
        output = machine.succeed(cmk_command(*args, **params), timeout=timedelta(minutes=10))
        return json.loads(output) if output.strip() else {}

    def wait_for(jq_filter, *args, **params):
        machine.wait_until_succeeds(
            f"{cmk_command(*args, **params)} | jq -e {shlex.quote(jq_filter)}",
            timeout=timedelta(minutes=15),
        )

    def simulator_templates():
        return int(machine.succeed(
            "mariadb --batch --skip-column-names"
            " -e \"SELECT COUNT(*) FROM cloud.vm_template WHERE hypervisor_type = 'Simulator'\""
        ))

    machine.wait_for_unit("cloudstack-management.service")

    with subtest("simulator data is loaded once the database is upgraded"), logs_on_failure():
        machine.wait_for_unit("cloudstack-management-simulator.service", timeout=timedelta(minutes=30))
        machine.succeed("mariadb -e 'SELECT COUNT(*) FROM simulator.mockhost'")
        assert simulator_templates() == 2, f"unexpected simulator template count {simulator_templates()}"

    with subtest("API comes up with the simulator plugin"), logs_on_failure():
        machine.wait_until_succeeds(
            f"curl -s -o /dev/null -w '%{{http_code}}' '{api}?command=listCapabilities&response=json' | grep -qx 401",
            timeout=timedelta(minutes=15),
        )
        machine.succeed("cloudstack-cloudmonkey sync")
        assert cmk("list", "apis", name="configureSimulator")["count"] == 1

    with subtest("the usage server starts on the upgraded database"), logs_on_failure():
        machine.wait_for_unit("cloudstack-usage.service")
        # It registers a job once it runs.
        machine.wait_until_succeeds(
            "mariadb --batch --skip-column-names -e 'SELECT COUNT(*) FROM cloud_usage.usage_job' | grep -qvx 0",
            timeout=timedelta(minutes=5),
        )
        # It waited for the database rather than fail and restart.
        machine.succeed("systemctl show -P NRestarts cloudstack-usage | grep -qx 0")
        machine.succeed("test -s /var/log/cloudstack/usage/usage.log")
        machine.succeed("grep -qx 1 /usr/local/libexec/sanity-check-last-id")
        # Jobs every 2 minutes, up to the current time, rather than daily for
        # the day before: the usage server reads this when it starts.
        cmk("update", "configuration", name="usage.stats.job.aggregation.range", value="2")
        machine.systemctl("restart cloudstack-usage.service")

    with subtest("an advanced zone deploys on simulated hosts"), logs_on_failure():
        zone = cmk(
            "create", "zone",
            name="Sandbox-simulator", networktype="Advanced", guestcidraddress="10.1.1.0/24",
            dns1="10.147.28.6", internaldns1="10.147.28.6",
        )["zone"]

        pnet = cmk(
            "create", "physicalnetwork",
            zoneid=zone["id"], name="Sandbox-pnet", isolationmethods="VLAN",
            broadcastdomainrange="Zone", vlan="100-200",
        )["physicalnetwork"]
        for traffic in ["Guest", "Management", "Public"]:
            cmk("add", "traffictype", physicalnetworkid=pnet["id"], traffictype=traffic)
        cmk("update", "physicalnetwork", id=pnet["id"], state="Enabled")

        provider = cmk(
            "list", "networkserviceproviders", name="VirtualRouter", physicalnetworkid=pnet["id"]
        )["networkserviceprovider"][0]
        element = cmk("list", "virtualrouterelements", nspid=provider["id"])["virtualrouterelement"][0]
        cmk("configure", "virtualrouterelement", id=element["id"], enabled="true")
        cmk("update", "networkserviceprovider", id=provider["id"], state="Enabled")

        cmk(
            "create", "vlaniprange",
            zoneid=zone["id"], vlan="50", forvirtualnetwork="true",
            gateway="192.168.2.1", netmask="255.255.255.0", startip="192.168.2.2", endip="192.168.2.200",
        )
        pod = cmk(
            "create", "pod",
            zoneid=zone["id"], name="POD0",
            gateway="172.16.15.1", netmask="255.255.255.0", startip="172.16.15.2", endip="172.16.15.200",
        )["pod"]
        cluster = cmk(
            "add", "cluster",
            zoneid=zone["id"], podid=pod["id"], clustername="C0",
            hypervisor="Simulator", clustertype="CloudManaged",
        )["cluster"][0]
        for host in ["h0", "h1"]:
            cmk(
                "add", "host",
                zoneid=zone["id"], podid=pod["id"], clusterid=cluster["id"], hypervisor="Simulator",
                url=f"http://sim/c0/{host}", username="root", password="password",
            )
        cmk(
            "create", "storagepool",
            zoneid=zone["id"], podid=pod["id"], clusterid=cluster["id"],
            name="PS0", url="nfs://10.147.28.6/export/home/sandbox/primary0",
        )
        cmk(
            "add", "imagestore",
            zoneid=zone["id"], provider="NFS",
            name="SS0", url="nfs://10.147.28.6/export/home/sandbox/secondary",
        )
        cmk("update", "zone", id=zone["id"], allocationstate="Enabled")

        wait_for('.count == 2 and all(.host[]; .state == "Up")', "list", "hosts", type="Routing", zoneid=zone["id"])

    with subtest("system VMs start and the secondary storage VM connects"), logs_on_failure():
        wait_for('.count == 2 and all(.systemvm[]; .state == "Running")', "list", "systemvms", zoneid=zone["id"])
        wait_for('.count == 1 and .host[0].state == "Up"', "list", "hosts", type="SecondaryStorageVM", zoneid=zone["id"])

    with subtest("a VM deploys in an isolated network"), logs_on_failure():
        template_name = "CentOS 5.6 (64-bit) no GUI (Simulator)"
        wait_for(
            f'any(.template[]; .name == "{template_name}" and .isready)',
            "list", "templates", templatefilter="featured", zoneid=zone["id"],
        )
        template = next(
            t for t in cmk("list", "templates", templatefilter="featured", zoneid=zone["id"])["template"]
            if t["name"] == template_name
        )

        network_offering = cmk(
            "list", "networkofferings", name="DefaultIsolatedNetworkOfferingWithSourceNatService"
        )["networkoffering"][0]
        network = cmk(
            "create", "network",
            zoneid=zone["id"], name="test", displaytext="test", networkofferingid=network_offering["id"],
        )["network"]
        service_offering = cmk("list", "serviceofferings", name="Small Instance")["serviceoffering"][0]

        vm = cmk(
            "deploy", "virtualmachine",
            zoneid=zone["id"], templateid=template["id"], serviceofferingid=service_offering["id"],
            networkids=network["id"], name="test-vm",
        )["virtualmachine"]
        assert vm["state"] == "Running", f"unexpected VM state {vm['state']}"
        router = cmk("list", "routers", networkid=network["id"])["router"][0]
        assert router["state"] == "Running", f"unexpected router state {router['state']}"

    with subtest("the usage server records the VM's running time"), logs_on_failure():
        today = machine.succeed("date -u +%F").strip()
        # An immediate job, besides the recurring ones.
        cmk("generate", "usagerecords")
        wait_for(
            f'any(.usagerecord[]?; .usageid == "{vm["id"]}")',
            "list", "usagerecords", startdate=today, enddate=today, type=1,
        )

    with subtest("the VM is destroyed"), logs_on_failure():
        cmk("destroy", "virtualmachine", id=vm["id"], expunge="true")
        assert cmk("list", "virtualmachines", zoneid=zone["id"]).get("count", 0) == 0

    with subtest("simulator data is not loaded twice"):
        machine.systemctl("restart cloudstack-management-simulator.service")
        machine.require_unit_state("cloudstack-management-simulator.service", "active")
        assert simulator_templates() == 2, f"unexpected simulator template count {simulator_templates()}"
  '';
}
