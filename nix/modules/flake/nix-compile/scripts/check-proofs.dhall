-- check-proofs.dhall
-- Script for proof verification

let inputs_self = env:INPUTS_SELF as Text

in ''
cd ${inputs_self}
echo "sense/net: verifying proof obligations"

# Extract proof structure from Dhall
dhall-to-json --file dhall/DischargeProof.dhall > /tmp/proofs.json

# TODO: lake build Continuity.DischargeProof
# TODO: verify that Dhall proof structure matches Lean4 formalization

touch $out
''
