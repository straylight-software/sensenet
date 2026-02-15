-- build-phase.dhall
-- Build phase script for flake-module

let prelude_path = env:PRELUDE_PATH as Text
let buckconfig_local_file = env:BUCKCONFIG_LOCAL_FILE as Text
let targets = env:TARGETS as Text

in ''
export HOME=$TMPDIR

# Set up prelude
mkdir -p nix/build
ln -sf ${prelude_path} nix/build/prelude

# Generate buckconfig.local
cp ${buckconfig_local_file} .buckconfig.local

# Build targets
buck2 build ${targets}
''
