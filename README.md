# cloudstack-nix

[Apache CloudStack](https://cloudstack.apache.org/) on NixOS: the management
server, the KVM agent and the usage server, built from source with Nix, set up
by NixOS modules, and tested end to end in NixOS VMs.

Currently packages **CloudStack 4.23.0.0**.

## Try it

```sh
nix run github:Q-t1/cloudstack-nix#demo
```

boots a VM running the management server with the simulator hypervisor, which
simulates hosts, storage and system VMs, and deploys a zone on it, with a
network and a VM. The VM's console is in the terminal: follow the deployment
with `journalctl -fu cloudstack-demo`, then open <http://localhost:8080/client>
and log in as `admin` / `password`. The first boot takes a few minutes, while
the management server sets up its database.

The VM keeps its state in `./cloudstack-demo.qcow2`; `poweroff` stops it, and
deleting that file starts over. It needs KVM, 4 GB of memory and port 8080,
which it only forwards from the loopback address. Until there is a binary
cache (see [Roadmap](#roadmap)), the first run builds CloudStack from source:
about 20 minutes on 12 cores.

## Start a cloud

```sh
nix flake init -t github:Q-t1/cloudstack-nix
```

creates a flake with two machines to adapt: a management server, with its
database and the usage server, and a KVM host. See [Usage](#usage) and
[KVM hosts](#kvm-hosts) for what the modules set up.

## What it does

- **Builds CloudStack from source**: the Maven reactor, the Vue web UI and
  the system VM scripts, in cheap packaging derivations on top of one heavy
  Java build. It follows upstream's packaging rather than copying it: the
  launchers run what upstream's systemd units run, and a cheap check names
  the upstream files that a CloudStack bump changed. See
  [Following upstream](#following-upstream).
- **Sets up the services declaratively**: the modules do what
  `cloudstack-setup-databases` and `cloudstack-setup-agent` do, from options,
  with upstream's configuration files and secrets as systemd credentials.
- **Prepares KVM hosts the way the management server expects them**:
  certificates from its CA, libvirt over TLS for live migration, VNC over TLS
  for the console proxy, UEFI guests.
- **Tests it all in NixOS VMs**: the first start and the web UI; a zone on the
  simulator, billed by the usage server; a zone on two nested KVM hosts with
  NFS storage, up to a guest VM reached through its virtual router, its
  console over TLS, live migration and a UEFI VM. See [Roadmap](#roadmap) for
  what is not covered yet.

## Outputs

| Output | Description |
| --- | --- |
| `packages.x86_64-linux.cloudstack-management` | Management server: launcher, jars, web UI, base SQL schema |
| `packages.x86_64-linux.cloudstack-agent` | KVM agent: launcher, jars, libvirt hook, host setup script |
| `packages.x86_64-linux.cloudstack-usage` | Usage server: launcher, jars, default configuration |
| `packages.x86_64-linux.cloudstack-common` | Scripts and system VM patch files shared by both |
| `packages.x86_64-linux.cloudstack-ui` | Web UI (Vue), built with `buildNpmPackage` |
| `packages.x86_64-linux.cloudstack-build` | Maven reactor build: staging tree of the build artifacts |
| `packages.x86_64-linux.cloudstack-systemvm-template-kvm` | The KVM system VM template (518 MB download), for `systemVmTemplates` |
| `legacyPackages.x86_64-linux.cloudstackPackages` | The package scope that the packages come from, see [Package set](#package-set) |
| `nixosModules.cloudstack-management` | `services.cloudstack.management` |
| `nixosModules.cloudstack-agent` | `services.cloudstack.agent`, see [KVM hosts](#kvm-hosts) |
| `nixosModules.default` | Both modules |
| `overlays.default` | Adds `cloudstackPackages` (a scope), `cloudstack-management`, `cloudstack-agent` and `cloudstack-usage` |
| `apps.x86_64-linux.demo` | A VM with a zone on the simulator, see [Try it](#try-it) |
| `templates.default` | A management server and a KVM host, see [Start a cloud](#start-a-cloud) |
| `checks.x86_64-linux.upstream-files` | Fails when a CloudStack bump changes upstream files that the flake follows by hand, see [Following upstream](#following-upstream) |
| `checks.x86_64-linux.template` | Evaluates the template's machines, without building them: catches option changes and failed assertions in seconds |
| `checks.x86_64-linux.formatting` | Fails on Nix files that `nix fmt` would change |
| `checks.x86_64-linux.nixos-management` | NixOS VM test: first start, API, web UI, restart |
| `checks.x86_64-linux.nixos-simulator` | NixOS VM test: an advanced zone and a VM on the simulator hypervisor, and the usage server's records for the VM |
| `checks.x86_64-linux.nixos-demo` | NixOS VM test: the demo's zone, network and VM |
| `checks.x86_64-linux.nixos-kvm` | NixOS VM test: a zone on KVM hosts with NFS storage, its system VMs and a guest VM, reached through its virtual router and its console over TLS, and live-migrated, then a UEFI VM (needs nested virtualisation) |

## Usage

```nix
{
  inputs.cloudstack-nix.url = "github:Q-t1/cloudstack-nix";

  outputs = { nixpkgs, cloudstack-nix, ... }: {
    nixosConfigurations.cloudstack = nixpkgs.lib.nixosSystem {
      modules = [
        cloudstack-nix.nixosModules.default
        {
          nixpkgs.hostPlatform = "x86_64-linux";
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

The web UI is at `http://<host>:8080/client`; log in as `admin` / `password`
and change that password. The first start takes a few minutes: the server
upgrades the base schema (CloudStack 4.0) to its own version.

### Package set

The modules default to this flake's packages, built with its own locked
nixpkgs: the build that its checks test, whatever nixpkgs your system has.
With `inputs.cloudstack-nix.inputs.nixpkgs.follows = "nixpkgs"`, they are
built with yours instead, a combination the checks have not tested, whose
Maven and npm dependency hashes may not match. With the overlay, the modules
default to its packages, also built with your nixpkgs.

The packages come from a scope, `cloudstackPackages`, so an override applies
to all of them, e.g. to run on JDK 21, which upstream supports too (only the
launchers change; the Maven build stays on JDK 17):

```nix
# cloudstack-nix is the flake input, passed through specialArgs.
{ pkgs, cloudstack-nix, ... }:
let
  cloudstack = cloudstack-nix.legacyPackages.x86_64-linux.cloudstackPackages.overrideScope (
    final: prev: { jre = pkgs.jdk21_headless; }
  );
in
{
  services.cloudstack.management.package = cloudstack.cloudstack-management;
  services.cloudstack.management.usage.package = cloudstack.cloudstack-usage;
  services.cloudstack.agent.package = cloudstack.cloudstack-agent;
}
```

### What the module sets up

- A local MariaDB (`database.createLocally`, the default) with the settings
  recommended by the installation guide, the `cloud` and `cloud_usage`
  databases and the database user. The base schema is loaded once, into an
  empty database. This replaces `cloudstack-setup-databases`.
- `db.properties`, `server.properties` and `environment.properties`: upstream's,
  with the entries of `settings.db`, `settings.server` and
  `settings.environment` in place of upstream's with the same keys. The
  defaults set what `cloudstack-setup-databases` would (node address, database
  connection, encryption) and what the module's options decide (ports, web UI,
  mount point). At each start, `/run/cloudstack-management/conf`, which stands
  for `/etc/cloudstack/management`, is assembled from the package's
  configuration files, these and the secrets.
- The JVM options of upstream's `cloudstack-management.default`, which
  `javaOptions` adds to.
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

### Usage server

```nix
services.cloudstack.management.usage.enable = true;
```

runs the usage server, `cloudstack-usage.service`, on the management server's
host, with the management server's database settings and secrets (upstream's
package links its `db.properties` and `key` to the management server's). On a
new installation, it waits for the management server to upgrade the schema to
its version and to create the usage job settings, rather than fail and restart.
It turns the usage events into usage records, which `listUsageRecords` returns.
Upstream runs it as root; here it runs as `cloud`.

Its job runs once a day by default, for the day before: see the global settings
`usage.stats.job.exec.time` and `usage.stats.job.aggregation.range` (in
minutes), which the usage server reads when it starts, so restart it after
changing them. `generateUsageRecords` runs a job right away. The usage sanity
check (`usage.sanity.check.interval`, off by default) keeps its state in
`/var/lib/cloudstack/usage/sanity-check-last-id`, rather than upstream's
`/usr/local/libexec`.

### Exploring a simulated zone

The [demo](#try-it) is the quickest way to browse a simulated zone; its
machine is `nixos/demo`, and `nixos/demo/deploy.sh` deploys the zone through
the API. To browse the zone that the simulator test deploys instead, run the
test's interactive driver with the web UI forwarded to the host:

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
| `/var/log/cloudstack/usage` | `usage.log`, with `usage.enable` |
| `/var/lib/cloudstack/usage` | The usage sanity check's state, with `usage.enable` |
| `/run/cloudstack-usage/conf` | The usage server's generated configuration, secrets included |

## KVM hosts

```nix
{
  imports = [ cloudstack-nix.nixosModules.default ];

  services.cloudstack.agent = {
    enable = true;
    # VNC ports of the VMs, for the console proxy, and live migration.
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
   all in `/etc/cloudstack/agent`, then has libvirtd listen with TLS and QEMU
   serve VNC over TLS;
2. runs `cloudstack-setup-agent`, which records the zone, pod, cluster, guid,
   management servers and network devices in `agent.properties` and starts the
   agent. Upstream's version also rewrites the host's network, libvirt,
   firewall and AppArmor/SELinux configuration; here that is the NixOS
   configuration's job.

The agent then connects to the management server on port 8250.

`tests/kvm.nix` deploys such a zone: a management server, a KVM host and an NFS
server for primary and secondary storage, with the system VM template from
`systemVmTemplates`. It waits for the secondary storage VM and the console proxy
to run on the host, registers a template from a URL (macchinina, the small image
of upstream's smoke tests), then deploys a VM in an isolated network. The VM
gets its address and its password from the network's virtual router. The NFS
server also plays the public network's gateway: it logs into the VM through
port forwarding on the network's public address, and once an egress rule allows
it, the VM reaches it through source NAT. It also opens the VM's console
through the console proxy, as the web UI's noVNC client does, and checks that
the console proxy reached the VM's VNC server over TLS. Then a second KVM host
joins the cluster, the VM is live-migrated to it and stays reachable, its
console too, and the test destroys it. Last, it deploys a VM with UEFI firmware
on the first host. The KVM hosts are themselves VMs, so the test needs nested
virtualisation.

The secondary storage VM refuses to download templates from private addresses
unless they are in the global setting `secstorage.allowed.internal.sites`, which
the management server only reads when it starts.

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
  `environment.properties` and `uefi.properties` are upstream's, with the
  entries of `settings.environment` and `settings.uefi` in place: the scripts
  that the management server runs, and the UEFI firmware of libvirtd's QEMU.
  The JVM options are upstream's (`cloudstack-agent.default`), which
  `javaOptions` adds to.
- What the management server's SSH setup expects: `/usr/share/cloudstack-common`
  (with the keystore scripts wrapped so that they find `keytool` and the other
  tools they need), a writable `/etc/cloudstack/agent`, `cloudstack-setup-agent`
  in `PATH`, sudo, and the SHA-2 MACs (`hmac-sha2-512`, `hmac-sha2-256`) in
  sshd's defaults: its SSH client has no encrypt-then-MAC algorithms, the only
  ones NixOS allows by default. `/etc/libvirt/libvirtd.conf` is only a marker:
  the keystore scripts check that it exists, and otherwise wait forever for a
  system VM.
- `br_netfilter` for security groups, `8021q` for guest VLANs, NFS client
  support (libvirtd mounts NFS storage pools itself, so `mount` is in its
  `PATH`), and `/var/lib/libvirt/images` for host-local primary storage.
- libvirtd's TLS socket (port 16514), for live migration: the agent migrates
  over `qemu+tls` to hosts secured with a certificate, and otherwise over
  unauthenticated `qemu+tcp`, which is not set up. The socket waits for the
  certificate that the management server issues when it adds the host; then
  `keystore-cert-import` runs `cloudstack-setup-agent -s`, which starts the
  socket and restarts libvirtd (VMs keep running), also when the certificate
  is renewed. libvirt on NixOS reads its PKI files from `/var/lib/pki` rather
  than `/etc/pki`, where `keystore-cert-import` links them, so the module
  links them there too. `openFirewall` opens 16514 and QEMU's migration ports
  (49152-49215).
- VNC over TLS, for the console proxy, as upstream sets it up on secured hosts:
  once the host has its certificate, `qemu.conf` gets `vnc_tls`, with a client
  certificate required (`vnc_tls_x509_verify`) and the host's certificate in
  `/var/lib/pki/libvirt-vnc`. The console proxy presents its own, from the
  CloudStack CA. `qemu.conf` is rewritten at each start of libvirtd, so the
  restart by `cloudstack-setup-agent -s` applies it to the VMs started
  afterwards; until then VNC is plain. `openFirewall` opens the VNC ports
  (5900-6100).
- UEFI guests (`boottype=UEFI`), with the firmware of libvirtd's QEMU, which
  `settings.uefi` names. The secure boot firmware has no keys enrolled. The
  agent reports UEFI support, which the management server requires to place
  UEFI VMs on the host, when that firmware exists; upstream's asks `dpkg` or
  `rpm` whether an `ovmf` package is installed.

### Paths

| Path | Content |
| --- | --- |
| `/var/lib/cloudstack/agent` | `agent.properties`, the agent's keystore and certificates; `/etc/cloudstack/agent` links here |
| `/var/log/cloudstack/agent` | `agent.log` |
| `/usr/share/cloudstack-common` | Scripts and system VM patch files, at the path the management server uses |
| `/var/lib/pki` | libvirt's CA, certificates and keys, and QEMU's for VNC (`libvirt-vnc`): links to the host's certificate in `/var/lib/cloudstack/agent` |

## Following upstream

The packages and modules stay as close to upstream's packages as NixOS
allows, so that a CloudStack bump brings upstream's changes along, or fails
where it cannot:

- The launchers run what upstream's systemd units run: the JVM options,
  classpath and main class of `packaging/systemd/*.default`, mapped to the
  packages' paths. A classpath entry or `/etc`/`/usr` path that the build does
  not know how to map fails it. `javaOptions` only adds to upstream's options.
- The configuration files are upstream's, as shipped in the packages, with
  only what upstream's setup tools would change in them
  (`cloudstack-setup-databases`, `cloudstack-setup-agent`) and what the
  modules' options decide, from the `settings.*` options. Upstream's other
  entries, and new ones in later versions, come through as they are.
- Source and script patches use `substituteInPlace --replace-fail`, which
  fails the build if upstream moves the code they patch.
- What the flake still follows by hand is pinned by hash in
  `pkgs/cloudstack/upstream-files.nix`: upstream's setup tools, systemd units,
  Debian packaging and keystore scripts. The cheap check
  `checks.x86_64-linux.upstream-files` (it only needs the source) fails when a
  bump changes one of them, and says what to review. It also compares the sudo
  commands of `cloudstack-sudoers.in` with `pkgs/cloudstack/sudo-commands.nix`,
  and the system VM template version of `pom.xml` with `source.nix`.

## Differences from the upstream packages

On purpose, because NixOS manages the system declaratively:

- There is no `/etc/cloudstack/management` or `/etc/cloudstack/usage`. Their
  contents are assembled at each start in `/run/cloudstack-management/conf` and
  `/run/cloudstack-usage/conf`, from the package's files, the `settings.*`
  options and systemd credentials. The tools that edit them
  (`cloudstack-setup-databases`, `-setup-management`, `-setup-encryption`,
  `-migrate-databases`) are not shipped; the module does what they do. Unlike
  `cloudstack-setup-databases`, it never drops a database, and it keeps the
  database passwords and secret in plain text in that private directory rather
  than encrypted with the key (`ENC(...)`).
- `cloudstack-setup-agent` is a NixOS replacement, see [KVM hosts](#kvm-hosts):
  network, libvirt and firewall settings come from the NixOS configuration.
  With `-s` it starts libvirtd's TLS socket and restarts libvirtd, whose
  `qemu.conf` then gets the VNC TLS settings, rather than rewriting
  `libvirtd.conf` and `qemu.conf`. `cloudstack-agent-upgrade`, which renames
  bridges after an upgrade from CloudStack 4.0, is not shipped.
- systemd units: the agent is skipped until the host is added, rather than
  restarted every 10 s; the usage server runs as `cloud` in a sandbox rather
  than as root, and waits for the management server to set up the database.
- NixOS paths: the agent's UEFI firmware (QEMU's), libvirt's PKI files in
  `/var/lib/pki`, the links and markers the management server's host setup
  expects (`/usr/share/cloudstack-common`, `/etc/libvirt/libvirtd.conf`), and
  `/var/lib/cloudstack/usage/sanity-check-last-id` for the usage server.
- The MySQL settings come from the installation guide, which is not in the
  source tree, so `checks.upstream-files` cannot follow them.
- Source changes, all in `pkgs/cloudstack/build.nix`:
  - `"/bin/bash"` becomes `"bash"`, resolved from `PATH`. Not a store path:
    the same jars run inside the Debian system VMs.
  - `genisoimage` is also looked up in `PATH`; the ipmitool default is `ipmitool`.
  - The KVM agent runs `systemctl` (rolling maintenance), `lvs` and `lvchange`
    (CLVM) and `test` (multipath) from `PATH` rather than `/bin` and
    `/usr/sbin`.
  - The KVM agent reports UEFI support when the firmware of `uefi.properties`
    exists, rather than when `dpkg` or `rpm` report an `ovmf` package.
  - The install paths of the system VM template metadata, the CKS configuration
    and the extensions, and the usage sanity check's state file, become Java
    system properties, set by the launchers.
  - The simulator hypervisor plugin is built, but not into the client jar: it
    replaces the NFS secondary storage provider, so it only goes on the
    classpath with `simulator.enable`.
- Script interpreters are resolved from `PATH` (`#!/usr/bin/env bash`) rather
  than store paths, because some scripts are copied to XenServer/OVM3 hosts.
- `scripts/vm/systemvm/id_rsa.cloud`, a publicly known placeholder key
  upstream, links to the key the management server generates.
- The UI uses a regenerated `package-lock.json`: upstream's is out of sync with
  `package.json` (axios), so it cannot be installed offline.

### Upgrades

A new CloudStack version upgrades the database schema itself when its
management server starts, as with upstream's packages; agents and the usage
server follow. The system VM templates of the new version must be available:
update `systemVmTemplates`, or let the management server download them.

A NixOS rollback does not undo a schema upgrade, and an older management
server does not start on a newer schema. Back up the `cloud` and `cloud_usage`
databases before switching to a new CloudStack version, and restore them to
roll back.

## Building and updating

The Java build is heavy: `buildMavenPackage` compiles the whole reactor twice,
once to fetch dependencies (fixed-output) and once offline. Each pass takes
about 25 minutes on one core. Packaging lives in separate, cheap derivations
(`common.nix`, `management.nix`, `agent.nix`, `usage.nix`, `ui.nix`), so layout
changes do not rebuild Java.

To bump CloudStack:

1. In `pkgs/cloudstack/source.nix`, update `version`, the source `hash`, and the
   system VM template version and checksum file (see
   `project.systemvm.template.version` in upstream's `pom.xml`). If the
   template version changed, update `systemvmTemplates` too: the URLs, and the
   checksums from that file.
2. Run `nix build -L .#checks.x86_64-linux.upstream-files`, which only needs the
   source. It lists the upstream files followed by hand that changed, with what
   to review in this flake; after the review, update their hashes and
   `reviewed` in `pkgs/cloudstack/upstream-files.nix`.
3. Set `mvnHash = lib.fakeHash;` in `build.nix`, run
   `nix build .#cloudstack-build.fetchedMavenDeps`, and copy the reported hash.
4. Run `pkgs/cloudstack/update-ui-lockfile.sh`, set `npmDepsHash =
   lib.fakeHash;` in `ui.nix`, build `.#cloudstack-ui.npmDeps` and copy the hash.
5. Run `nix flake check -L`, which also runs the VM tests. The packages fail to
   build where upstream moved what they patch or map, see
   [Following upstream](#following-upstream).

## Roadmap

- CI with a binary cache, so nobody rebuilds the Maven reactor locally.
