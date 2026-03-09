# superconsole-ffi - C FFI bindings for Meta's superconsole TUI library
{
  lib,
  rustPlatform,
  pkg-config,
}:

let
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ../../src/vendor/superconsole;
    filter =
      path: type:
      # Exclude build artifacts
      !(lib.hasInfix "/target" path);
  };

in
rustPlatform.buildRustPackage {
  pname = "superconsole-ffi";
  inherit version src;

  cargoLock = {
    lockFile = ../../src/vendor/superconsole/Cargo.lock;
    # Allow git deps to be fetched
    allowBuiltinFetchGit = true;
  };

  nativeBuildInputs = [ pkg-config ];

  doCheck = false;

  postInstall = ''
    mkdir -p $out/include $out/lib

    # Copy libraries
    find target -name 'libsuperconsole_ffi.a' -path '*/release/*' -exec cp {} $out/lib/ \; 2>/dev/null || true
    find target -name 'libsuperconsole_ffi.so' -path '*/release/*' -exec cp {} $out/lib/ \; 2>/dev/null || true
    find target -name 'libsuperconsole_ffi.dylib' -path '*/release/*' -exec cp {} $out/lib/ \; 2>/dev/null || true

    # Copy header
    cp superconsole_c.h $out/include/
  '';

  meta = with lib; {
    description = "C FFI bindings for Meta's superconsole TUI library";
    license = licenses.mit;
    platforms = platforms.unix;
  };
}
