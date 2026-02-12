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

  checkPhase = ''
    runHook preCheck

    echo "sense/net: running test suite"
    echo "=============================="

    # Test 1: Dhall files type-check
    echo ""
    echo "Test 1: Dhall type checking"
    for f in dhall/*.dhall; do
      echo "  checking $f"
      dhall --file "$f" > /dev/null || {
        echo "FAIL: $f did not type-check"
        exit 1
      }
    done
    echo "  ✓ All Dhall files type-check"

    # Test 2: Proof obligations test file
    echo ""
    echo "Test 2: Proof obligations"
    if [ -f test/sensenet/proof-obligations.dhall ]; then
      dhall --file test/sensenet/proof-obligations.dhall > /dev/null || {
        echo "FAIL: proof-obligations.dhall did not type-check"
        exit 1
      }
      echo "  ✓ proof-obligations.dhall type-checks"
    fi

    # Test 3: Build graph test file
    echo ""
    echo "Test 3: Build graph"
    if [ -f test/sensenet/build-graph.dhall ]; then
      dhall --file test/sensenet/build-graph.dhall > /dev/null || {
        echo "FAIL: build-graph.dhall did not type-check"
        exit 1
      }
      echo "  ✓ build-graph.dhall type-checks"
    fi

    # Test 4: Package exports
    echo ""
    echo "Test 4: Package exports"
    dhall --file dhall/package.dhall > /dev/null || {
      echo "FAIL: dhall/package.dhall did not type-check"
      exit 1
    }
    echo "  ✓ dhall/package.dhall type-checks"

    # Test 5: to-buck2 transpiler
    echo ""
    echo "Test 5: to-buck2 transpiler"
    dhall --file dhall/to-buck2.dhall > /dev/null || {
      echo "FAIL: dhall/to-buck2.dhall did not type-check"
      exit 1
    }
    echo "  ✓ dhall/to-buck2.dhall type-checks"

    echo ""
    echo "=============================="
    echo "All tests passed"

    runHook postCheck
  '';

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
