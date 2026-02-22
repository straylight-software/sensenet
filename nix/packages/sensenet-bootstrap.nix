# sensenet-bootstrap - Minimal bootstrap build
# Only the essential dependencies from sensenet.cabal
# Fast to build, used for initial bootstrap before self-hosting
{
  mkDerivation,
  lib,
  # Core deps (from sensenet.cabal)
  async,
  base,
  bytestring,
  containers,
  crypton,
  dhall,
  directory,
  filepath,
  memory,
  process,
  text,
  time,
  unix,
}:
mkDerivation {
  pname = "sensenet";
  version = "0.4.0";
  src = lib.cleanSource ../../src/sensenet;
  isLibrary = false;
  isExecutable = true;
  executableHaskellDepends = [
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
  executableSystemDepends = [ ];
  doCheck = false;
  configureFlags = [
    "--ghc-options=-j"
    "--ghc-options=-threaded"
    "--ghc-options=-rtsopts"
    "--ghc-options=-with-rtsopts=-N"
  ];
  description = "SENSE // NET - Bootstrap build (minimal deps)";
  license = lib.licenses.mit;
  mainProgram = "sensenet";
  patchPhase = ":";
}
