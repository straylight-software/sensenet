# sensenet-local - Local build without heavy remote execution deps
# Same as bootstrap for now, but separate package for future expansion
# (e.g., could add local-only features that don't need gRPC/protobuf)
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
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = coreDeps;
  executableHaskellDepends = [
    base
    directory
    text
  ];
  executableSystemDepends = [ ];
  doCheck = false;
  configureFlags = [
    "--ghc-options=-j"
    "--ghc-options=-threaded"
    "--ghc-options=-rtsopts"
    "--ghc-options=-with-rtsopts=-N"
  ];
  description = "SENSE // NET - Local build (no remote execution deps)";
  license = lib.licenses.mit;
  mainProgram = "sensenet";
}
