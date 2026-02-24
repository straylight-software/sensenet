# sensenet - SENSE // NET build system
# Pure Haskell implementation - no FFI dependencies
# Full build with all optional features (remote execution, etc.)
{
  mkDerivation,
  lib,
  # Core deps (from sensenet.cabal)
  aeson,
  async,
  base,
  bytestring,
  containers,
  crypton,
  deepseq,
  dhall,
  directory,
  either,
  filepath,
  hashable,
  hostname,
  katip,
  memory,
  microlens,
  process,
  text,
  text-short,
  time,
  unix,
  unordered-containers,
  vector,
}:
let
  # Shared dependencies for library and executable
  coreDeps = [
    aeson
    async
    base
    bytestring
    containers
    crypton
    deepseq
    dhall
    directory
    either
    filepath
    hashable
    hostname
    katip
    memory
    microlens
    process
    text
    text-short
    time
    unix
    unordered-containers
    vector
  ];
in
mkDerivation {
  pname = "sensenet";
  version = "0.4.0";
  src = lib.cleanSource ../../src/sensenet;
  # Library + executable
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = coreDeps;
  executableHaskellDepends = [
    base
    directory
    text
  ];
  # No FFI dependencies - pure Haskell
  executableSystemDepends = [ ];
  doCheck = false;
  # Parallel GHC compilation + threaded runtime
  configureFlags = [
    "--ghc-options=-j"
    "--ghc-options=-threaded"
    "--ghc-options=-rtsopts"
    "--ghc-options=-with-rtsopts=-N"
  ];
  description = "SENSE // NET - Pure Haskell build system with content-addressed caching";
  license = lib.licenses.mit;
  mainProgram = "sensenet";
}
