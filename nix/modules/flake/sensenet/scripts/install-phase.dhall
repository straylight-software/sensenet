-- install-phase.dhall
-- Install phase script for flake-module

let install_binaries = env:INSTALL_BINARIES as Text
let targets = env:TARGETS as Text

in ''
mkdir -p $out

# Install binaries if enabled
if [ "${install_binaries}" = "1" ]; then
  mkdir -p $out/bin
  find buck-out/v2/gen -type f -executable -not -name "*.so" -not -name "*.a" 2>/dev/null | while read bin; do
    if file "$bin" | grep -q "ELF.*executable"; then
      install -m 755 "$bin" "$out/bin/" 2>/dev/null || true
    fi
  done
fi

# Always create a marker file
echo "${targets}" > $out/.sensenet-targets
''
