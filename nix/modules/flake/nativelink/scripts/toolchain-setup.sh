#!/usr/bin/env bash
# Fetch Nix toolchains from cache on worker startup
set -euo pipefail

TOOLCHAIN_PATHS="@toolchainPaths@"

echo "Fetching toolchain paths from cache.nixos.org..."

for path in $TOOLCHAIN_PATHS; do
	if [[ ! -e "$path" ]]; then
		echo "Fetching: $path"
		nix copy --from https://cache.nixos.org "$path" || {
			echo "Warning: Failed to fetch $path from cache, trying to build..."
			nix build --no-link "$path" || echo "Failed to obtain $path"
		}
	else
		echo "Already present: $path"
	fi
done

echo "Toolchain setup complete"
