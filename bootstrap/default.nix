# Bootstrap derivation for sensenet
#
# Builds sensenet using GHC directly in a pure Nix environment.
# This derivation is the ONLY way to build sensenet from scratch.
# Once built, sensenet can build itself and everything else.
#
# The BUCK file exists for documentation and future Buck2 integration,
# but the actual build uses GHC directly for simplicity and reproducibility.
#
# Usage:
#   nix-build bootstrap/default.nix
#   # or via flake:
#   nix build .#sensenet-bootstrap
#
{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
}:

let
  # Source modules for the library

  # HyperConsole modules

  # GHC with all required packages for bootstrap
  ghc = pkgs.haskell.packages.ghc912.ghcWithPackages (hp: [
    hp.aeson
    hp.ansi-terminal
    hp.async
    hp.bytestring
    hp.colour
    hp.containers
    hp.crypton
    hp.deepseq
    hp.dhall
    hp.directory
    hp.either
    hp.filepath
    hp.hashable
    hp.hostname
    hp.katip
    hp.memory
    hp.microlens
    hp.mtl
    hp.process
    hp.text
    hp.text-short
    hp.time
    hp.unix
    hp.unordered-containers
    hp.vector
  ]);

  # GHC with test dependencies
  ghcTest = pkgs.haskell.packages.ghc912.ghcWithPackages (hp: [
    hp.aeson
    hp.ansi-terminal
    hp.async
    hp.bytestring
    hp.colour
    hp.containers
    hp.crypton
    hp.deepseq
    hp.dhall
    hp.directory
    hp.either
    hp.filepath
    hp.hashable
    hp.hostname
    hp.katip
    hp.memory
    hp.microlens
    hp.mtl
    hp.process
    hp.text
    hp.text-short
    hp.time
    hp.unix
    hp.unordered-containers
    hp.vector
    # Test deps
    hp.tasty
    hp.tasty-hunit
    hp.tasty-quickcheck
    hp.temporary
    hp.random
  ]);

in
{
  # Bootstrap sensenet binary
  sensenet = pkgs.stdenv.mkDerivation {
    pname = "sensenet-bootstrap";
    version = "0.4.0";

    src = lib.cleanSource ../.;

    nativeBuildInputs = [ ghc ];

    buildPhase =
      let
        script = pkgs.replaceVars ./build-sensenet.sh { inherit ghc; };
      in
      ''
        bash ${script}
      '';

    installPhase = ''
      mkdir -p $out/bin
      cp sensenet $out/bin/
    '';

    meta = {
      description = "sensenet - the best build system in the world (bootstrap)";
      license = lib.licenses.mit;
      platforms = lib.platforms.unix;
    };
  };

  # Test binary
  test = pkgs.stdenv.mkDerivation {
    pname = "sensenet-test";
    version = "0.4.0";

    src = lib.cleanSource ../.;

    nativeBuildInputs = [ ghcTest ];

    buildPhase =
      let
        script = pkgs.replaceVars ./build-test.sh { inherit ghcTest; };
      in
      ''
        bash ${script}
      '';

    installPhase = ''
      mkdir -p $out/bin
      cp sensenet-test $out/bin/
    '';

    # Run tests as part of the build
    doCheck = true;
    checkPhase = ''
      ./sensenet-test
    '';

    meta = {
      description = "sensenet test suite";
      license = lib.licenses.mit;
      platforms = lib.platforms.unix;
    };
  };
}
