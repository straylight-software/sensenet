# sensenet - SENSE // NET build system
# Pure Haskell implementation - no FFI dependencies
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
  # Shell command execution
  shelly,
}:
mkDerivation {
  pname = "sensenet";
  version = "0.3.0";
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
    # Shell commands
    shelly
  ];
  # No FFI dependencies - pure Haskell
  executableSystemDepends = [ ];
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
    shelly
  ];
  testSystemDepends = [ ];
  doCheck = false;
  # Parallel GHC compilation + threaded runtime
  configureFlags = [
    "--ghc-options=-j"
    "--ghc-options=-threaded"
    "--ghc-options=-rtsopts"
    "--ghc-options=-with-rtsopts=-N"
  ];
  description = "SENSE // NET — Pure Haskell build system with content-addressed caching";
  license = lib.licenses.mit;
  mainProgram = "sensenet";
  patchPhase = ":";
}
