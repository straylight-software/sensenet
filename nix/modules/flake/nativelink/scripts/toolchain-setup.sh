#!/usr/bin/env bash
# toolchain-setup.sh - Set up toolchain paths for NativeLink workers
#
# Substituted variables:
#   @toolchainPaths@ - Space-separated list of Nix store paths
#
# This script is run inside the worker container to set up PATH and
# other environment variables for build actions.

set -euo pipefail

# Toolchain paths from Nix (substituted at build time)
TOOLCHAIN_PATHS="@toolchainPaths@"

# Add each toolchain path to PATH
for path in $TOOLCHAIN_PATHS; do
  if [[ -d "$path/bin" ]]; then
    export PATH="$path/bin:$PATH"
  fi
done

# Set up library paths
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
for path in $TOOLCHAIN_PATHS; do
  if [[ -d "$path/lib" ]]; then
    export LD_LIBRARY_PATH="$path/lib:$LD_LIBRARY_PATH"
  fi
done

echo "Toolchain setup complete. PATH contains ${#TOOLCHAIN_PATHS} entries."
