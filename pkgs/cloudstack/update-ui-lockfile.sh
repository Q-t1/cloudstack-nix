#!/usr/bin/env nix-shell
#!nix-shell -i bash -p nodejs_22 jq
# Regenerates ui-package-lock.json from the pinned CloudStack source.
#
# Upstream's ui/package-lock.json is stale (lockfile v1; package.json wants
# axios ^0.31.1, the lockfile pins 0.21.4), so `npm ci` cannot work offline.
# This keeps every locked version that still satisfies package.json and only
# resolves what is missing. Run it after bumping source.nix, then update
# npmDepsHash in ui.nix.
#
# --legacy-peer-deps matches the npm 6 lockfile upstream maintains (no peer
# dependencies, e.g. antd's react); ui.nix passes it to npm as well.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
flake=$(cd "$here/../.." && pwd)

src=$(nix build --no-link --print-out-paths "$flake#cloudstack-management.src")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cp "$src/ui/package.json" "$src/ui/package-lock.json" "$work/"
chmod u+w "$work"/*
(
  cd "$work"
  npm install --package-lock-only --ignore-scripts --no-audit --no-fund \
    --legacy-peer-deps --lockfile-version 3
)

jq -e '.lockfileVersion == 3' "$work/package-lock.json" > /dev/null
cp "$work/package-lock.json" "$here/ui-package-lock.json"
echo "Updated $here/ui-package-lock.json; now refresh npmDepsHash in ui.nix."
