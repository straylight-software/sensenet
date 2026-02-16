{
  lib,
  rustPlatform,
  pkg-config,
}:

let
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ../../src/vendor/dice;
    filter =
      path: type:
      # Exclude build artifacts
      !(lib.hasInfix "/target" path);
  };

in
rustPlatform.buildRustPackage {
  pname = "dice-ffi";
  inherit version src;

  cargoLock = {
    lockFile = ../../src/vendor/dice/Cargo.lock;
    # Allow git deps to be fetched
    allowBuiltinFetchGit = true;
  };

  # Build just dice_ffi
  buildAndTestSubdir = "dice_ffi";

  nativeBuildInputs = [ pkg-config ];

  doCheck = false;

  postInstall = ''
    mkdir -p $out/include $out/lib

    # Copy libraries
    find target -name 'libdice_ffi.a' -path '*/release/*' -exec cp {} $out/lib/ \; 2>/dev/null || true
    find target -name 'libdice_ffi.so' -path '*/release/*' -exec cp {} $out/lib/ \; 2>/dev/null || true
    find target -name 'libdice_ffi.dylib' -path '*/release/*' -exec cp {} $out/lib/ \; 2>/dev/null || true

    # Copy header
    cp dice_ffi/include/dice_ffi.h $out/include/
  '';

  meta = with lib; {
    description = "C FFI bindings for DICE incremental computation engine";
    license = licenses.mit;
    platforms = platforms.unix;
  };
}
