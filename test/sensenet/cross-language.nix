# test/sensenet/cross-language.nix
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                                                     // test // cross-language //
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# FAILING TEST: Cross-language dependency tracking between Nix, Dhall, and buck2
#
# This test exercises the data flow:
#   Nix toolchain config → Dhall Build.dhall → Starlark .bzl → buck2 build
#
# nix-compile should:
#   1. Trace store paths from Nix through to buck2 actions
#   2. Verify Dhall coeffects match actual Nix derivation requirements
#   3. Detect type mismatches between layers
#
# Currently fails because:
#   1. nix-compile --cross-lang-report not implemented
#   2. No Nix → Dhall type bridge
#   3. Starlark output not tracked
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{
  lib,
  pkgs,
}:
let
  # ────────────────────────────────────────────────────────────────────────────
  # Layer 1: Nix toolchain paths
  # nix-compile should infer: { cc : Path, cxx : Path, ar : Path, ... }
  # ────────────────────────────────────────────────────────────────────────────

  cxx-toolchain = {
    cc = "${pkgs.llvmPackages_18.clang}/bin/clang";
    cxx = "${pkgs.llvmPackages_18.clang}/bin/clang++";
    ar = "${pkgs.llvmPackages_18.bintools}/bin/llvm-ar";
    nm = "${pkgs.llvmPackages_18.bintools}/bin/llvm-nm";
    strip = "${pkgs.llvmPackages_18.bintools}/bin/llvm-strip";
    ld = "${pkgs.llvmPackages_18.lld}/bin/ld.lld";
    sysroot = "${pkgs.llvmPackages_18.libcxx}";
  };

  # ────────────────────────────────────────────────────────────────────────────
  # Layer 2: Nix → Dhall bridge
  # This generates a Dhall file from Nix toolchain config
  # ────────────────────────────────────────────────────────────────────────────

  # FAILING: nix-compile should verify this generates valid Dhall
  toolchain-dhall = pkgs.writeText "toolchain-generated.dhall" ''
    -- Auto-generated from Nix toolchain configuration
    -- DO NOT EDIT - regenerate with `nix run .#gen-toolchain-dhall`

    let Toolchain = ../dhall/Toolchain.dhall

    in  Toolchain::{
        , cc = "${cxx-toolchain.cc}"
        , cxx = "${cxx-toolchain.cxx}"
        , ar = "${cxx-toolchain.ar}"
        , ld = "${cxx-toolchain.ld}"
        , sysroot = Some "${cxx-toolchain.sysroot}"
        }
  '';

  # ────────────────────────────────────────────────────────────────────────────
  # Layer 3: Dhall → Starlark generation
  # The Dhall toolchain compiles to .buckconfig.local entries
  # ────────────────────────────────────────────────────────────────────────────

  # FAILING: Should verify Starlark output is consistent with Dhall input
  buckconfig-local = pkgs.writeText "buckconfig.local" ''
    [cxx]
    cc = ${cxx-toolchain.cc}
    cxx = ${cxx-toolchain.cxx}
    ar = ${cxx-toolchain.ar}
    nm = ${cxx-toolchain.nm}
    strip = ${cxx-toolchain.strip}
    ld = ${cxx-toolchain.ld}

    [cxx#sysroot]
    path = ${cxx-toolchain.sysroot}
  '';

  # ────────────────────────────────────────────────────────────────────────────
  # Test: Type consistency across layers
  # ────────────────────────────────────────────────────────────────────────────

  # FAILING: nix-compile should detect this type mismatch
  # We're passing a string where a path is expected
  broken-toolchain = {
    cc = "clang";  # ERROR: should be Path, not String
    cxx = "${pkgs.llvmPackages_18.clang}/bin/clang++";
    ar = null;  # ERROR: should be Path, not Null
    ld = "${pkgs.llvmPackages_18.lld}/bin/ld.lld";
  };

  # FAILING: nix-compile should detect this inconsistency
  # The buckconfig references a different clang than the Nix derivation
  inconsistent-buckconfig = pkgs.writeText "buckconfig-inconsistent.local" ''
    [cxx]
    # This path doesn't match cxx-toolchain.cc!
    cc = /usr/bin/clang
    cxx = ${cxx-toolchain.cxx}
  '';

  # ────────────────────────────────────────────────────────────────────────────
  # Test: Coeffect tracking through layers
  # ────────────────────────────────────────────────────────────────────────────

  # A derivation that needs network access
  # FAILING: Should propagate coeffect requirement to Dhall layer
  fetched-source = pkgs.fetchFromGitHub {
    owner = "example";
    repo = "example";
    rev = "main";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };

  # Build that uses fetched source
  # FAILING: nix-compile should infer this needs Resource.network
  build-with-fetch = pkgs.stdenv.mkDerivation {
    name = "build-with-fetch";
    src = fetched-source;
    buildPhase = ''
      echo "Building..."
    '';
    installPhase = ''
      mkdir -p $out
      touch $out/result
    '';
  };

in
{
  # Export for testing
  inherit
    cxx-toolchain
    toolchain-dhall
    buckconfig-local
    broken-toolchain
    inconsistent-buckconfig
    build-with-fetch
    ;

  # Test metadata
  __tests = {
    type-consistency = {
      description = "Verify type consistency across Nix → Dhall → Starlark";
      status = "FAILING";
      reason = "nix-compile --cross-lang-report not implemented";
    };
    coeffect-tracking = {
      description = "Track coeffect requirements through layers";
      status = "FAILING";
      reason = "Coeffect inference not implemented for fetchFromGitHub";
    };
    path-validation = {
      description = "Validate store paths in generated configs";
      status = "FAILING";
      reason = "Path vs String distinction not tracked";
    };
  };
}
