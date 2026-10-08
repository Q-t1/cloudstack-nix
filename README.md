# cloudstack-nix

The [Apache CloudStack](https://cloudstack.apache.org/) management server,
built from source with Nix and run as a NixOS service.

Currently packages **CloudStack 4.23.0.0**. The management server, its database
setup and the web UI are covered by a NixOS VM test. Hypervisor hosts (KVM
agent), the usage server and real secondary storage are not covered yet, see
[Roadmap](#roadmap).

## Outputs

| Output | Description |
| --- | --- |
| `packages.x86_64-linux.cloudstack-management` | Management server: launcher, jars, web UI, scripts, base SQL schema |
| `packages.x86_64-linux.cloudstack-ui` | Web UI (Vue), built with `buildNpmPackage` |
| `packages.x86_64-linux.cloudstack-build` | Maven reactor build: staging tree of the build artifacts |
| `nixosModules.cloudstack-management` | `services.cloudstack.management` |
| `overlays.default` | Adds `cloudstackPackages` (a scope) and `cloudstack-management` |
| `checks.x86_64-linux.nixos-management` | NixOS VM test |

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
  (`cmk`).
- Optional HTTPS on the embedded Jetty (`https.*`), and UI branding through
  `ui.settings`, which is merged into the UI's `config.json`.

### Paths

| Path | Content |
| --- | --- |
| `/var/lib/cloudstack/management` | Home of `cloud`, including the system VM SSH key pair |
| `/var/lib/cloudstack/secrets` | Generated secrets. Back them up with the database. |
| `/var/lib/cloudstack/extensions` | Extensions; the bundled samples are refreshed at each start |
| `/var/lib/cloudstack/mnt` | Secondary storage mount points |
| `/var/log/cloudstack/management` | `management-server.log`, `apilog.log`, `access.log` |
| `/run/cloudstack-management/conf` | Generated configuration, secrets included |

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
- Script interpreters are resolved from `PATH` (`#!/usr/bin/env bash`) rather
  than store paths, because some scripts are copied to XenServer/OVM3 hosts.
- `scripts/vm/systemvm/id_rsa.cloud`, a publicly known placeholder key
  upstream, links to the key the management server generates.
- The UI uses a regenerated `package-lock.json`: upstream's is out of sync with
  `package.json` (axios), so it cannot be installed offline.

## Building and updating

The Java build is heavy: `buildMavenPackage` compiles the whole reactor twice,
once to fetch dependencies (fixed-output) and once offline. Each pass takes
about 25 minutes on one core. Packaging lives in separate, cheap derivations
(`management.nix`, `ui.nix`), so layout changes do not rebuild Java.

To bump CloudStack:

1. In `pkgs/cloudstack/source.nix`, update `version`, the source `hash`, and the
   system VM template version and checksum file (see
   `project.systemvm.template.version` in upstream's `pom.xml`).
2. Set `mvnHash = lib.fakeHash;` in `build.nix`, run
   `nix build .#cloudstack-build.fetchedMavenDeps`, and copy the reported hash.
3. Run `pkgs/cloudstack/update-ui-lockfile.sh`, set `npmDepsHash =
   lib.fakeHash;` in `ui.nix`, build `.#cloudstack-ui.npmDeps` and copy the hash.
4. Run `nix flake check -L`, which also runs the VM test.

The `substituteInPlace --replace-fail` patches fail the build if upstream moves
the code they patch.

## Roadmap

- KVM agent module (`services.cloudstack.agent`). This is the hard part: libvirt
  hooks, host networking, and an `agent.properties` that the agent rewrites.
- Usage server. Its artifacts are already in `cloudstack-build`.
- A VM test that deploys a zone, either with the simulator (`-Dsimulator`) or
  with nested KVM and NFS secondary storage.
- CI with a binary cache, so nobody rebuilds the Maven reactor locally.
