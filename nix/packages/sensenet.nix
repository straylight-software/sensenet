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
  # Scheduler deps
  stm,
  time,
  unix,
  # TUI deps (brick)
  brick,
  microlens-mtl,
  microlens-th,
  vty,
  vty-crossplatform,
  # Test deps
  tasty,
  tasty-hunit,
  tasty-quickcheck,
  QuickCheck,
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
    # Scheduler
    stm
    time
    unix
    # TUI (Brick)
    brick
    microlens-mtl
    microlens-th
    vty
    vty-crossplatform
    # Test deps
    tasty
    tasty-hunit
    tasty-quickcheck
    QuickCheck
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
  testHaskellDepends = [
    # Test framework
    tasty
    tasty-hunit
    tasty-quickcheck
    QuickCheck
    # Same deps as main executable
    async
    base
    bytestring
    containers
    dhall
    directory
    filepath
    process
    text
    stm
    time
    unix
    brick
    microlens-mtl
    microlens-th
    microlens
    vty
    vty-crossplatform
    aeson
    conduit
    crypton
    grapesy
    grpc-spec
    memory
    network
    proto-lens
    proto-lens-runtime
    vector
  ];
  testSystemDepends = [
    dice-ffi
    superconsole-ffi
  ];
  doCheck = false;
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
