# sensenet-bootstrap - Minimal bootstrap build
# Only the essential dependencies from sensenet.cabal
# Fast to build, used for initial bootstrap before self-hosting
{
  mkDerivation,
  lib,
  # Core deps (from sensenet.cabal)
  aeson,
  ansi-terminal,
  async,
  base,
  bytestring,
  colour,
  containers,
  crypton,
  deepseq,
  dhall,
  directory,
  either,
  filepath,
  hashable,
  hostname,
  hyperconsole,
  katip,
  memory,
  microlens,
  mtl,
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
    ansi-terminal
    async
    base
    bytestring
    colour
    containers
    crypton
    deepseq
    dhall
    directory
    either
    filepath
    hashable
    hostname
    hyperconsole
    katip
    memory
    microlens
    mtl
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
  description = "SENSE // NET - Bootstrap build (minimal deps)";
  license = lib.licenses.mit;
  mainProgram = "sensenet";
}
