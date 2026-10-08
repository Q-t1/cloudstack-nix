# The Vue web UI (ui/). Upstream builds it with `npm install && npm run build`
# outside of Maven and copies dist/ into the management server's webapp.
{
  lib,
  buildNpmPackage,
  nodejs_22,
  cloudstackSource,
}:

buildNpmPackage {
  pname = "cloudstack-ui";
  inherit (cloudstackSource) version src;
  sourceRoot = "${cloudstackSource.src.name}/ui";

  # Upstream CI still uses Node 16; 22 is the oldest one left in nixpkgs.
  nodejs = nodejs_22;
  npmDepsHash = "sha256-6C46HwmhDu3Mh9W7gucW72wUeWiXwzPiTt1HQn8E6B4=";

  # The lockfile follows npm 6 semantics: peer dependencies (antd's react)
  # are not installed.
  npmFlags = [ "--legacy-peer-deps" ];

  # Only dev tooling has native addons (e.g. deasync); skip their install
  # scripts rather than compiling them with node-gyp.
  npmRebuildFlags = [ "--ignore-scripts" ];

  # webpack 4 hashes with md4, which OpenSSL 3 only provides via the legacy
  # provider.
  env.NODE_OPTIONS = "--openssl-legacy-provider";

  # Upstream's lockfile is out of sync with package.json (axios), so npm would
  # need the registry. Use a consistent one, see update-ui-lockfile.sh.
  # `npm run build` also runs the pre/post hooks, which fill in the
  # docHelpMappings of config.json.
  postPatch = ''
    cp ${./ui-package-lock.json} package-lock.json
    patchShebangs prebuild.sh postbuild.sh
  '';

  installPhase = ''
    runHook preInstall
    cp -r dist "$out"
    runHook postInstall
  '';

  meta = {
    description = "Apache CloudStack web UI";
    homepage = "https://cloudstack.apache.org/";
    license = lib.licenses.asl20;
    platforms = lib.platforms.all;
  };
}
