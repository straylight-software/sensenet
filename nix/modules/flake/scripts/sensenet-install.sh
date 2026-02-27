#!/usr/bin/env bash
# Install phase for sensenet builds (auto-detect mode)
# Environment variables:
#   output_name - name of the target to find

runHook preInstall

mkdir -p "$out/bin"

# Auto-detect: copy executables from buck-out
find buck-out/v2/gen -type f -executable -name "${output_name}*" | head -1 | xargs -I{} cp {} "$out/bin/"

runHook postInstall
