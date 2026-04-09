#!/usr/bin/env bash
# Install phase for sensenet builds (explicit output mode)
# Environment variables:
#   output_path - path within buck-out to copy

runHook preInstall

mkdir -p "$out/bin"

# Copy the specified output
cp buck-out/v2/gen/*/"$output_path" "$out/bin/"

runHook postInstall
