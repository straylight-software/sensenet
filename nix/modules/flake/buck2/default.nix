# nix/modules/flake/buck2/default.nix
#
# Buck2 project flake module.
#
# Provides a declarative way to define Buck2 projects within a Nix flake,
# generating both packages (Nix derivations that run buck2 build) and
# development shells with toolchains pre-configured.
#
# Usage in flake.nix:
#
#   imports = [ aleph-0xff.flakeModules.buck2 ];
#
#   buck2.projects.myproject = {
#     src = ./.;
#     targets = [ "//src/..." ];
#     toolchain = {
#       cxx.enable = true;
#       haskell.enable = true;
#       haskell.packages = hp: [ hp.aeson hp.text ];
#       rust.enable = true;
#     };
#   };
#
# This creates:
#   - packages.buck2-myproject: Builds the targets via buck2
#   - devShells.buck2-myproject: Dev shell with all toolchains
#
{ inputs }:
{
  imports = [ (import ./flake-module.nix { inherit inputs; }) ];
}
