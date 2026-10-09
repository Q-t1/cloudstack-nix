# cloudstack-nix

The [Apache CloudStack](https://cloudstack.apache.org/) management server,
built from source with Nix and run as a NixOS service, and the KVM agent.

Currently packages **CloudStack 4.23.0.0**. NixOS VM tests cover the management
server, its database setup and the web UI, and deploy a zone with a VM on the
simulator hypervisor. The KVM agent is packaged but has no NixOS module yet;
real hypervisor hosts, the usage server and real secondary storage are not
covered yet, see [Roadmap](#roadmap).

## Outputs

| Output | Description |
| --- | --- |
| `packages.x86_64-linux.cloudstack-management` | Management server: launcher, jars, web UI, base SQL schema |
| `packages.x86_64-linux.cloudstack-agent` | KVM agent: launcher, jars, libvirt hook, host setup script, see [KVM agent](#kvm-agent) |
| `packages.x86_64-linux.cloudstack-common` | Scripts and system VM patch files shared by both |
| `packages.x86_64-linux.cloudstack-ui` | Web UI (Vue), built with `buildNpmPackage` |
| `packages.x86_64-linux.cloudstack-build` | Maven reactor build: staging tree of the build artifacts |
| `nixosModules.cloudstack-management` | `services.cloudstack.management` |
| `overlays.default` | Adds `cloudstackPackages` (a scope), `cloudstack-management` and `cloudstack-agent` |
| `checks.x86_64-linux.nixos-management` | NixOS VM test: first start, API, web UI, restart |
| `checks.x86_64-linux.nixos-simulator` | NixOS VM test: an advanced zone and a VM on the simulator hypervisor |

## Usage

```nix
{
  inputs.cloudstack-nix.url = "github:Q-t1/cloudstack-nix";

  outputs = { nixpkgs, cloudstack-nix, ... }: {
    nixosConfigurations.cloudstack = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        cloudstack-nix.nixosModules.default
        {
          services.cloudstack.management = {
            enable = true;
            # The address other management servers use to reach this one.
            nodeAddress = "192.0.2.10";
            openFirewall = true;
          };
        }
      ];
    };
  };
}
```

The module builds the package with your system's nixpkgs, so the overlay is
optional. The web UI is at `http://<host>:8080/client`; log in as `admin` /
`password` and change that password. The first start takes a few minutes: the
server upgrades the base schema (CloudStack 4.0) to its own version.

### What the module sets up

- A local MariaDB (`database.createLocally`, the default) with the settings
  recommended by the installation guide, the `cloud` and `cloud_usage`
  databases and the database user. The base schema is loaded once, into an
  empty database. This replaces `cloudstack-setup-databases`.
- `db.properties`, `server.properties` and `environment.properties`, generated
  from `settings.db`, `settings.server` and `settings.environment` (defaults
  follow upstream). At each start they are assembled with the secrets into
  `/run/cloudstack-management/conf`, which goes first on the classpath.
- Secrets passed as systemd credentials: database password, management server
  key and database encryption key. Missing ones are generated in
  `/var/lib/cloudstack/secrets`.
- The `cloud` user (CloudStack only creates the system VM SSH key pair when it
  runs as `cloud`), the sudo rules for the commands the server runs as root
  (NFS mounts, system VM template seeding), NFS client support, and CloudMonkey
  (`cloudstack-cloudmonkey`).
- Optional HTTPS on the embedded Jetty (`https.*`), and UI branding through
  `ui.settings`, which is merged into the UI's `config.json`.
- Optionally, for development and testing, the simulator hypervisor
  (`simulator.enable`): simulated hosts, storage and system VMs, enough to
  deploy zones and VMs from the API or the UI. Hosts are added with URLs like
  `http://sim/c0/h0`. The module creates the `simulator` database; once the
  first start has upgraded the schema, `cloudstack-management-simulator.service`
  loads upstream's simulator templates, so wait for it before adding a zone.
  `tests/simulator.nix` deploys a whole zone.

### Exploring a simulated zone

To browse the zone that the simulator test deploys, run the test's interactive
driver with the web UI forwarded to the host:

```sh
QEMU_NET_OPTS=hostfwd=tcp:127.0.0.1:8080-:8080 \
  nix run .#checks.x86_64-linux.nixos-simulator.driverInteractive
```

At the Python prompt, `run_tests()` runs the test (a few minutes) and leaves the
VM running. Then open <http://localhost:8080/client> and log in as `admin` /
`password`, or call `machine.shell_interact()` for a root shell with
`cloudstack-cloudmonkey`. The test destroys its VM at the end; new ones can use
the "CentOS 5.6 (64-bit) no GUI (Simulator)" template.

### Paths

| Path | Content |
| --- | --- |
| `/var/lib/cloudstack/management` | Home of `cloud`, including the system VM SSH key pair |
| `/var/lib/cloudstack/secrets` | Generated secrets. Back them up with the database. |
| `/var/lib/cloudstack/extensions` | Extensions; the bundled samples are refreshed at each start |
| `/var/lib/cloudstack/mnt` | Secondary storage mount points |
| `/var/log/cloudstack/management` | `management-server.log`, `apilog.log`, `access.log` |
| `/run/cloudstack-management/conf` | Generated configuration, secrets included |

## KVM agent

`cloudstack-agent` is packaged, but there is no NixOS module to run it yet.

- `bin/cloudstack-agent` starts the agent. Its configuration directory
  (`CLOUDSTACK_CONF_DIR`, default `/etc/cloudstack/agent`) holds
  `agent.properties`, `environment.properties`, `log4j-cloud.xml` and
  `uefi.properties`, with upstream's defaults in `share/cloudstack-agent/conf`.
  It must be writable: the agent records its state in `agent.properties` and
  keeps its keystore next to it.
- `bin/cloudstack-setup-agent` replaces upstream's script, which the management
  server runs over SSH when it adds a host. Upstream's version also rewrites
  the host's network, libvirt, firewall and AppArmor/SELinux configuration.
  This one only writes the management servers, zone, pod, cluster, guid and
  network devices into `agent.properties` and restarts
  `cloudstack-agent.service`; the rest is the NixOS configuration's job.
- `share/cloudstack-agent/lib/libvirtqemuhook` is the libvirt qemu hook.
  `cloudstack-ssh` (into a system VM) and `cloudstack-guest-tool` (QEMU guest
  agent queries) are upstream's helpers.

## Differences from the upstream packages

- There is no `/etc/cloudstack/management`. Tools that edit it
  (`cloudstack-setup-databases`, `-setup-management`, `-setup-encryption`,
  `-migrate-databases`) are not shipped; the module covers what they do.
- Source changes, all in `pkgs/cloudstack/build.nix`:
  - `"/bin/bash"` becomes `"bash"`, resolved from `PATH`. Not a store path:
    the same jars run inside the Debian system VMs.
  - `genisoimage` is also looked up in `PATH`; the ipmitool default is `ipmitool`.
  - The install paths of the system VM template metadata, the CKS configuration
    and the extensions become Java system properties, set by the launcher.
  - The simulator hypervisor plugin is built, but not into the client jar: it
    replaces the NFS secondary storage provider, so it only goes on the
    classpath with `simulator.enable`.
- Script interpreters are resolved from `PATH` (`#!/usr/bin/env bash`) rather
  than store paths, because some scripts are copied to XenServer/OVM3 hosts.
- `scripts/vm/systemvm/id_rsa.cloud`, a publicly known placeholder key
  upstream, links to the key the management server generates.
- `cloudstack-setup-agent` is a NixOS replacement, see [KVM agent](#kvm-agent).
  `cloudstack-agent-upgrade`, which renames bridges after an upgrade from
  CloudStack 4.0, is not shipped.
- The UI uses a regenerated `package-lock.json`: upstream's is out of sync with
  `package.json` (axios), so it cannot be installed offline.

## Building and updating

The Java build is heavy: `buildMavenPackage` compiles the whole reactor twice,
once to fetch dependencies (fixed-output) and once offline. Each pass takes
about 25 minutes on one core. Packaging lives in separate, cheap derivations
(`common.nix`, `management.nix`, `agent.nix`, `ui.nix`), so layout changes do
not rebuild Java.

To bump CloudStack:

1. In `pkgs/cloudstack/source.nix`, update `version`, the source `hash`, and the
   system VM template version and checksum file (see
   `project.systemvm.template.version` in upstream's `pom.xml`).
2. Set `mvnHash = lib.fakeHash;` in `build.nix`, run
   `nix build .#cloudstack-build.fetchedMavenDeps`, and copy the reported hash.
3. Run `pkgs/cloudstack/update-ui-lockfile.sh`, set `npmDepsHash =
   lib.fakeHash;` in `ui.nix`, build `.#cloudstack-ui.npmDeps` and copy the hash.
4. Run `nix flake check -L`, which also runs the VM tests.

The `substituteInPlace --replace-fail` patches fail the build if upstream moves
the code they patch.

## Roadmap

- KVM agent module (`services.cloudstack.agent`): libvirtd and the qemu hook,
  host bridges, declared settings merged into the `agent.properties` that the
  agent rewrites, and what the management server's host setup over SSH
  expects: `/usr/share/cloudstack-common/scripts/util/keystore-setup`, a
  writable `/etc/cloudstack/agent` and `cloudstack-setup-agent` in `PATH`. Then
  a VM test with two nodes that adds a KVM host and waits for it to be `Up`.
- With the next Maven rebuild: require the agent artifacts in `build.nix`
  (it only keeps them if present), and resolve `/bin/systemctl`, used by the
  agent's rolling maintenance, from `PATH`.
- Usage server. Its artifacts are already in `cloudstack-build`.
- A VM test that deploys a zone with nested KVM and NFS secondary storage. The
  simulator test covers the orchestration, but no real host, storage or system
  VM.
- CI with a binary cache, so nobody rebuilds the Maven reactor locally.
