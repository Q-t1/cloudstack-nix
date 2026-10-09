# cloudstack-nix

The [Apache CloudStack](https://cloudstack.apache.org/) management server and
KVM agent, built from source with Nix and run as NixOS services.

Currently packages **CloudStack 4.23.0.0**. NixOS VM tests cover the management
server, its database setup and the web UI, deploy a zone with a VM on the
simulator hypervisor, and deploy a zone on a KVM host with NFS storage, up to its
system VMs. Guest VMs on KVM, live migration and the usage server are not
covered yet, see [Roadmap](#roadmap).

## Outputs

| Output | Description |
| --- | --- |
| `packages.x86_64-linux.cloudstack-management` | Management server: launcher, jars, web UI, base SQL schema |
| `packages.x86_64-linux.cloudstack-agent` | KVM agent: launcher, jars, libvirt hook, host setup script |
| `packages.x86_64-linux.cloudstack-common` | Scripts and system VM patch files shared by both |
| `packages.x86_64-linux.cloudstack-ui` | Web UI (Vue), built with `buildNpmPackage` |
| `packages.x86_64-linux.cloudstack-build` | Maven reactor build: staging tree of the build artifacts |
| `packages.x86_64-linux.cloudstack-systemvm-template-kvm` | The KVM system VM template (518 MB download), for `systemVmTemplates` |
| `nixosModules.cloudstack-management` | `services.cloudstack.management` |
| `nixosModules.cloudstack-agent` | `services.cloudstack.agent`, see [KVM hosts](#kvm-hosts) |
| `nixosModules.default` | Both modules |
| `overlays.default` | Adds `cloudstackPackages` (a scope), `cloudstack-management` and `cloudstack-agent` |
| `checks.x86_64-linux.nixos-management` | NixOS VM test: first start, API, web UI, restart |
| `checks.x86_64-linux.nixos-simulator` | NixOS VM test: an advanced zone and a VM on the simulator hypervisor |
| `checks.x86_64-linux.nixos-kvm` | NixOS VM test: a zone on a KVM host with NFS storage, up to its system VMs (needs nested virtualisation) |

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
- System VM templates from the Nix store (`systemVmTemplates`, e.g.
  `cloudstackPackages.systemvmTemplates.kvm-x86_64`), which the server copies to
  new secondary storage. Otherwise it downloads them from
  download.cloudstack.org when secondary storage is added.
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

## KVM hosts

```nix
{
  imports = [ cloudstack-nix.nixosModules.default ];

  services.cloudstack.agent = {
    enable = true;
    # VNC ports of the VMs, for the console proxy.
    openFirewall = true;
  };

  # The bridge that the zone's traffic labels name (cloudbr0 by default),
  # with the host's address.
  networking.bridges.cloudbr0.interfaces = [ "eno1" ];
  networking.interfaces.cloudbr0.ipv4.addresses = [
    { address = "192.0.2.21"; prefixLength = 24; }
  ];

  # The management server sets the host up over SSH.
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    # /var/lib/cloudstack/management/.ssh/id_rsa.pub on the management server
    "ssh-rsa AAAA..."
  ];
}
```

Then add the host to a KVM cluster, from the UI or with `addHost`: URL
`http://<host address>`, user `root` (or a user with passwordless sudo) and its
password. The management server tries its own key first, so with the key above
any password will do. Before that, set the global setting `host` to the address
that agents and system VMs connect to: it defaults to the address of the
management server's default route, which may be on the wrong network.

When the host is added, the management server logs in over SSH and

1. has the host generate a key pair and a certificate request (`keystore-setup`),
   signs it with its CA and installs the certificate (`keystore-cert-import`),
   all in `/etc/cloudstack/agent`;
2. runs `cloudstack-setup-agent`, which records the zone, pod, cluster, guid,
   management servers and network devices in `agent.properties` and starts the
   agent. Upstream's version also rewrites the host's network, libvirt,
   firewall and AppArmor/SELinux configuration; here that is the NixOS
   configuration's job.

The agent then connects to the management server on port 8250.

`tests/kvm.nix` deploys such a zone: a management server, a KVM host and an NFS
server for primary and secondary storage, with the system VM template from
`systemVmTemplates`. It waits for the secondary storage VM and the console proxy
to run on the host. The KVM host is itself a VM, so the test needs nested
virtualisation.

### What the module sets up

- libvirtd, running QEMU as root, with upstream's `qemu.conf` settings
  (`security_driver = "none"`, `vnc_listen = "0.0.0.0"`) and CloudStack's qemu
  hook, which rewrites bridge names in incoming migrations and runs the scripts
  in `/etc/libvirt/hooks/custom`.
- `cloudstack-agent.service`, skipped until `agent.properties` has a guid, that
  is until the host is added (or `settings.agent.guid` is set), rather than
  restarted every few seconds. The agent keeps state in `agent.properties`, so
  the file is kept: it starts as upstream's default, and at each start the
  entries of `settings.agent` replace the ones with the same keys.
  `uefi.properties` points at the UEFI firmware of libvirtd's QEMU.
- What the management server's SSH setup expects: `/usr/share/cloudstack-common`
  (with the keystore scripts wrapped so that they find `keytool` and the other
  tools they need), a writable `/etc/cloudstack/agent`, `cloudstack-setup-agent`
  in `PATH`, sudo, and the SHA-2 MACs (`hmac-sha2-512`, `hmac-sha2-256`) in
  sshd's defaults: its SSH client has no encrypt-then-MAC algorithms, the only
  ones NixOS allows by default. `/etc/libvirt/libvirtd.conf` is only a marker:
  the keystore scripts check that it exists, and otherwise wait forever for a
  system VM.
- `br_netfilter` for security groups, NFS client support (libvirtd mounts NFS
  storage pools itself, so `mount` is in its `PATH`), and
  `/var/lib/libvirt/images` for host-local primary storage.

Not set up yet: live migration (libvirtd does not listen on the network) and
UEFI guests (the agent detects UEFI support by asking `dpkg` or `rpm` whether
an `ovmf` package is installed, so it reports none).

### Paths

| Path | Content |
| --- | --- |
| `/var/lib/cloudstack/agent` | `agent.properties`, the agent's keystore and certificates; `/etc/cloudstack/agent` links here |
| `/var/log/cloudstack/agent` | `agent.log` |
| `/usr/share/cloudstack-common` | Scripts and system VM patch files, at the path the management server uses |

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
- `cloudstack-setup-agent` is a NixOS replacement, see [KVM hosts](#kvm-hosts).
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
   `project.systemvm.template.version` in upstream's `pom.xml`). If the
   template version changed, update `systemvmTemplates` too: the URLs, and the
   checksums from that file.
2. Set `mvnHash = lib.fakeHash;` in `build.nix`, run
   `nix build .#cloudstack-build.fetchedMavenDeps`, and copy the reported hash.
3. Run `pkgs/cloudstack/update-ui-lockfile.sh`, set `npmDepsHash =
   lib.fakeHash;` in `ui.nix`, build `.#cloudstack-ui.npmDeps` and copy the hash.
4. Run `nix flake check -L`, which also runs the VM tests.

The `substituteInPlace --replace-fail` patches fail the build if upstream moves
the code they patch.

## Roadmap

- A guest VM on KVM in `tests/kvm.nix`: a guest network (virtual router) and a
  VM from a small template, served over HTTP inside the test since the
  secondary storage VM downloads templates from a URL.
- KVM live migration: libvirtd listening with TLS, using the certificates the
  management server installs in `/etc/cloudstack/agent`.
- With the next Maven rebuild, Java changes for the agent:
  - detect UEFI support from the firmware files rather than from `dpkg`/`rpm`;
  - resolve `/bin/systemctl` (rolling maintenance), `/usr/sbin/lvs` and
    `/usr/sbin/lvchange` (CLVM) and `/bin/test` (multipath) from `PATH`;
  - require the agent artifacts in `build.nix`, which only keeps them if
    present.
- Usage server. Its artifacts are already in `cloudstack-build`.
- CI with a binary cache, so nobody rebuilds the Maven reactor locally.
