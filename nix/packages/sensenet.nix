# sensenet - SENSE // NET build system
# Pure Haskell implementation - no FFI dependencies
# Full build with all optional features (remote execution, etc.)
{
  mkDerivation,
  lib,
  installShellFiles,
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
  # Shared dependencies for library and executable
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

  # Build the Haskell package
  sensenet-unwrapped = mkDerivation {
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
  };
in
# Wrap with shell completions
sensenet-unwrapped.overrideAttrs (old: {
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ installShellFiles ];
  postInstall = (old.postInstall or "") + ''
    # Install shell completions for bash, zsh, and fish
    installShellCompletion --bash --name sensenet.bash \
      <($out/bin/sensenet complete bash)
    installShellCompletion --zsh --name _sensenet \
      <($out/bin/sensenet complete zsh)
    installShellCompletion --fish --name sensenet.fish \
      <($out/bin/sensenet complete fish)
  '';
})
