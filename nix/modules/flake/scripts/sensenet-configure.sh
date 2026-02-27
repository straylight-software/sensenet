#!/usr/bin/env bash
# Configure phase for sensenet builds
# Environment variables:
#   buckconfig_file   - path to buckconfig file
#   sensenet_prelude  - path to prelude

runHook preConfigure

# Write .buckconfig.local with Nix store paths
cp "$buckconfig_file" .buckconfig.local

# Link prelude if needed
if [ ! -d "prelude" ] && [ ! -L "prelude" ]; then
  ln -s "$sensenet_prelude" prelude
fi

runHook postConfigure
