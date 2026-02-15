-- check-nix.dhall
-- Script for running nix-compile check

let inputs_self = env:INPUTS_SELF as Text
let profile = env:PROFILE as Text
let path_args = env:PATH_ARGS as Text

in ''
cd ${inputs_self}
echo "sense/net: running nix-compile (profile: ${profile})"
nix-compile -p ${profile} ${path_args}
touch $out
''
