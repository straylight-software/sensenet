# nix/lib/render-dhall.nix
#
# Centralized render-dhall function for generating text from Dhall templates.
#
# Usage:
#   { pkgs, lib }:
#   let
#     render-dhall = import ../../lib/render-dhall.nix { inherit pkgs lib; };
#   in
#   render-dhall "my-script" ./my-template.dhall { var1 = "value1"; var2 = "value2"; }
#
{ pkgs, lib }:
let
  # Convert vars attrset to env var exports
  # Dhall expects UPPER_SNAKE_CASE env vars
  env-vars = lib.mapAttrs' (
    k: v: lib.nameValuePair (lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] k)) (toString v)
  );
in

name: src: vars:
pkgs.runCommand name
  (
    {
      nativeBuildInputs = [ pkgs.haskellPackages.dhall ];
    }
    // env-vars vars
  )
  ''
    dhall text --file ${src} > $out
  ''
