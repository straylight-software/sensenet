# test/sensenet/check.nix
#
# Nix derivation that runs the sense/net test suite.
# Used by: checks.${system}.sensenet-tests
#
{
  lib,
  stdenv,
  dhall,
  dhall-json,
  bash,
  coreutils,
}:

stdenv.mkDerivation {
  pname = "sensenet-tests";
  version = "0.1.0";

  src = ../..;

  nativeBuildInputs = [
    dhall
    dhall-json
    bash
    coreutils
  ];

  # Skip build phase
  dontBuild = true;

  checkPhase = builtins.readFile ./check-phase.sh;

  doCheck = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    echo "sensenet-tests: all checks passed" > $out/result
    runHook postInstall
  '';

  meta = {
    description = "sense/net test suite";
    license = lib.licenses.mit;
    maintainers = [ ];
  };
}
