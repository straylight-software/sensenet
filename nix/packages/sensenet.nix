# sensenet - SENSE // NET build system
# All-in-one Haskell package with integrated NativeLink client
{
  mkDerivation,
  lib,
  # Core deps
  async,
  base,
  bytestring,
  containers,
  dhall,
  directory,
  filepath,
  process,
  text,
  # NativeLink/gRPC deps (formerly nativelink-hs)
  aeson,
  conduit,
  crypton,
  grapesy,
  grpc-spec,
  memory,
  microlens,
  network,
  proto-lens,
  proto-lens-runtime,
  vector,
  # FFI
  dice-ffi,
  superconsole-ffi,
}:
mkDerivation {
  pname = "sensenet";
  version = "0.1.0";
  src = lib.cleanSource ../../.;
  isLibrary = false;
  isExecutable = true;
  executableHaskellDepends = [
    # Core
    async
    base
    bytestring
    containers
    dhall
    directory
    filepath
    process
    text
    # NativeLink/gRPC
    aeson
    conduit
    crypton
    grapesy
    grpc-spec
    memory
    microlens
    network
    proto-lens
    proto-lens-runtime
    vector
  ];
  executableSystemDepends = [
    dice-ffi
    superconsole-ffi
  ];
  # Parallel GHC compilation + threaded runtime
  configureFlags = [
    "--ghc-options=-j"
    "--ghc-options=-threaded"
    "--ghc-options=-rtsopts"
    "--ghc-options=-with-rtsopts=-N"
  ];
  description = "SENSE // NET — Typed builds with Dhall + DICE";
  license = lib.licenses.mit;
  mainProgram = "sensenet";
  patchPhase = ":";
}
