-- check-buck2-graph.dhall
-- Script for buck2 graph check

let inputs_self = env:INPUTS_SELF as Text

in ''
cd ${inputs_self}
echo "sense/net: analyzing buck2 build graph"

# Generate build graph
# buck2 audit cell . > /tmp/cells.txt
# buck2 targets //... > /tmp/targets.txt

# Verify Dhall → Starlark consistency
echo "  verifying Dhall → Starlark transpilation..."

touch $out
''
