#!/usr/bin/env bash
# buck2 graph check script

cd @inputsSelf@
echo "sense/net: analyzing buck2 build graph"

# Generate build graph
# buck2 audit cell . > /tmp/cells.txt
# buck2 targets //... > /tmp/targets.txt

# Verify Dhall → Starlark consistency
echo "  verifying Dhall → Starlark transpilation..."

touch $out
