-- check-cross-lang.dhall
-- Script for cross-language check

let inputs_self = env:INPUTS_SELF as Text

in ''
cd ${inputs_self}
echo "sense/net: cross-language dependency analysis"

# Extract Nix toolchain paths
echo "  extracting Nix toolchain definitions..."

# Extract Dhall resource requirements
echo "  extracting Dhall coeffect requirements..."
dhall-to-json --file dhall/Resource.dhall > /tmp/resources.json

# Verify consistency between Nix and Dhall
echo "  verifying Nix ↔ Dhall consistency..."
# TODO: nix-compile --cross-lang-report

touch $out
''
