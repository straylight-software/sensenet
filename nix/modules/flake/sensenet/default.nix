# nix/modules/flake/sensenet/default.nix
#
# Sensenet project flake module.
#
# Provides a declarative way to define build projects within a Nix flake,
# generating both packages (Nix derivations that run buck2 build) and
# development shells with toolchains pre-configured.
#
# Usage in flake.nix:
#
#   imports = [ sensenet.flakeModules.sensenet ];
#
#   sensenet.projects.myproject = {
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
#   - packages.sensenet-myproject: Builds the targets via buck2
#   - devShells.sensenet-myproject: Dev shell with all toolchains
#
# Backward compatibility:
#   - buck2.projects is aliased to sensenet.projects (deprecated)
#   - flakeModules.buck2 is aliased to flakeModules.sensenet (deprecated)
#
{ inputs }:
{
  _class = "flake";

  imports = [ (import ./flake-module.nix { inherit inputs; }) ];
}
