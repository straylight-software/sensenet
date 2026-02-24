# sensenet-static - Statically linked sensenet binary
#
# Build with: nix build .#sensenet-static
#
# This produces a fully static, portable Linux binary that can run
# on any x86_64 Linux system without any dependencies.
#
{ pkgsMusl, lib }:
let
  hlib = pkgsMusl.haskell.lib;

  # Use static Haskell packages with tests disabled for cross-compilation
  # pkgsMusl is pkgsStatic which uses musl libc
  haskellPackages = pkgsMusl.haskell.packages.ghc912.override {
    overrides = _self: super: {
      # Disable tests for packages that fail with cross-compilation
      # (they require -fexternal-interpreter which doesn't work for musl)
      vector = hlib.dontCheck super.vector;
    };
  };

  # Build sensenet with static linking flags
  sensenet = haskellPackages.mkDerivation {
    pname = "sensenet";
    version = "0.4.0";

    # Source is the src/sensenet directory
    src = lib.cleanSource ../../src/sensenet;

    isLibrary = false;
    isExecutable = true;

    executableHaskellDepends = with haskellPackages; [
      async
      base
      bytestring
      containers
      crypton
      dhall
      directory
      filepath
      memory
      process
      text
      time
      unix
    ];

    # Static linking flags
    configureFlags = [
      "--ghc-option=-optl-static"
      "--ghc-option=-optl-pthread"
      "--ghc-option=-threaded"
      "--ghc-option=-rtsopts"
      "--ghc-option=-with-rtsopts=-N"
      "--ghc-option=-O2"
      "--disable-shared"
      "--enable-executable-static"
    ];

    # Ensure static linking
    enableSharedExecutables = false;
    enableSharedLibraries = false;

    doCheck = false;

    postInstall = ''
      # Strip the binary to reduce size
      $STRIP $out/bin/sensenet || true
    '';

    description = "sensenet - Pure Haskell build system (static binary)";
    license = lib.licenses.mit;
    mainProgram = "sensenet";
  };
in
sensenet
