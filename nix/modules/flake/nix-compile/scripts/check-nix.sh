#!/usr/bin/env bash
# nix-compile check script

cd @inputsSelf@
echo "sense/net: running nix-compile (profile: @profile@)"
nix-compile -p @profile@ @pathArgs@
touch $out
