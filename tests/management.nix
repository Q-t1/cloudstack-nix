# Boots the management server against a local MariaDB, waits until it has
# upgraded the base schema to its own version, then uses the API and web UI.
{ self }:
{
  name = "cloudstack-management";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.cloudstack-management ];

      virtualisation = {
        memorySize = 4096;
        diskSize = 4096;
      };

      services.cloudstack.management = {
        enable = true;
        ui.settings.appTitle = "CloudStack on NixOS";
      };

      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];
    };

  testScript = ''
    import json
    from datetime import timedelta

    api = "http://localhost:8080/client/api"

    def dump_logs():
        for log in ["management-server.log", "access.log"]:
            print(machine.execute(f"tail -n 200 /var/log/cloudstack/management/{log}")[1])

    machine.wait_for_unit("cloudstack-management-init.service")
    machine.wait_for_unit("cloudstack-management.service")

    with subtest("API comes up after the database upgrade"):
        # Unauthenticated calls get a 401 once the API is up.
        try:
            machine.wait_until_succeeds(
                f"curl -s -o /dev/null -w '%{{http_code}}' '{api}?command=listCapabilities&response=json' | grep -qx 401",
                timeout=timedelta(minutes=30),
            )
        except Exception:
            dump_logs()
            raise

    with subtest("admin can log in and query the API"):
        login = json.loads(machine.succeed(
            "curl -sf -c /tmp/cookies"
            " --data-urlencode command=login --data-urlencode username=admin"
            " --data-urlencode password=password --data-urlencode response=json"
            f" {api}"
        ))
        sessionkey = login["loginresponse"]["sessionkey"]
        capabilities = json.loads(machine.succeed(
            f"curl -sf -b /tmp/cookies '{api}?command=listCapabilities&response=json&sessionkey={sessionkey}'"
        ))
        version = capabilities["listcapabilitiesresponse"]["capability"]["cloudstackversion"]
        assert version.startswith("4.23"), f"unexpected version {version}"

    with subtest("web UI is served with the configured config.json"):
        # Not piped into grep -q: it exits early and curl then fails (23).
        machine.succeed("curl -sf -o /tmp/index.html http://localhost:8080/client/index.html")
        machine.succeed("grep -qi '<html' /tmp/index.html")
        machine.succeed(
            "curl -sf http://localhost:8080/client/config.json"
            " | jq -e '.appTitle == \"CloudStack on NixOS\" and .apiBase == \"/client/api\"'"
        )

    with subtest("first start set up keys, mount parent and extensions"):
        machine.succeed("test -s /var/lib/cloudstack/management/.ssh/id_rsa")
        machine.succeed("test -x /var/lib/cloudstack/extensions/Proxmox/proxmox.sh")
        machine.succeed("curl -sf -b /tmp/cookies"
                        f" '{api}?command=listConfigurations&name=mount.parent&response=json&sessionkey={sessionkey}'"
                        " | jq -e '.listconfigurationsresponse.configuration[0].value == \"/var/lib/cloudstack/mnt\"'")

    with subtest("the configuration and JVM options are upstream's, with the settings"):
        conf = "/run/cloudstack-management/conf"
        # Upstream's whole configuration directory, as /etc/cloudstack/management.
        machine.succeed(f"test -s {conf}/java.security.ciphers -a -s {conf}/ehcache.xml -a -s {conf}/key")
        # Upstream's entries, with the module's in their place.
        machine.succeed(f"grep -qx 'db.cloud.validationQuery=/\\* ping \\*/ SELECT 1' {conf}/db.properties")
        machine.succeed(f"grep -qE '^db.cloud.encryption.type ?= ?file$' {conf}/db.properties")
        machine.succeed(f"[ $(grep -c '^db.cloud.password' {conf}/db.properties) -eq 1 ]")
        machine.succeed(f"grep -qx 'context.path=/client' {conf}/server.properties")
        # The options of upstream's cloudstack-management.default.
        cmdline = machine.succeed("tr '\\0' ' ' < /proc/$(systemctl show -P MainPID cloudstack-management)/cmdline")
        for option in ["-XX:+UseParallelGC", f"-Djava.security.properties={conf}/java.security.ciphers"]:
            assert option in cmdline, f"{option} not in {cmdline}"

    with subtest("restart keeps working with the existing database"):
        machine.systemctl("restart cloudstack-management.service")
        machine.wait_until_succeeds(
            f"curl -s -o /dev/null -w '%{{http_code}}' '{api}?command=listCapabilities&response=json' | grep -qx 401",
            timeout=timedelta(minutes=15),
        )

    with subtest("no log appender errors"):
        machine.fail("journalctl -u cloudstack-management.service | grep 'for appender SYSLOG'")
  '';
}
