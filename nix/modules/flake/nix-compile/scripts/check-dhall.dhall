-- check-dhall.dhall
-- Script for running Dhall type check

let inputs_self = env:INPUTS_SELF as Text

in ''
cd ${inputs_self}
echo "sense/net: type-checking Dhall configurations"

# Type-check each Dhall file
for f in dhall/*.dhall; do
  echo "  checking $f"
  dhall --file "$f" > /dev/null
done

# Verify package.dhall exports are consistent
echo "  checking dhall/package.dhall"
dhall --file dhall/package.dhall > /dev/null

touch $out
''
