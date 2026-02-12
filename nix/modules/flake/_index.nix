# nix/modules/flake/_index.nix
#
# Module index for sense/net — self-use only
# Downstream flakes import flakeModules.default
#
{ inputs, ... }:
{
  imports = [
    (import ./formatter.nix { inherit inputs; })
    ./lint.nix
    (import ./nixpkgs.nix { inherit inputs; })
    (import ./build/flake-module.nix { inherit inputs; })
    ./devshell.nix
    (import ./std.nix { inherit inputs; })
    (import ./nix-compile/default.nix { inherit inputs; })
  ];

  # Enable devshell for this repo
  # NOTE: sense.build.enable requires scripts/ directory which is missing
  sense.devshell.enable = true;
  sense.devshell.nv.enable = true;

  # Enable custom LLVM git toolchain for SM120 support
  sense.llvm-git.enable = true;

  # Enable nix-compile static analysis
  sense.nix-compile = {
    enable = true;
    profile = "strict";
    verify-dhall = true;
    cross-language = false; # TODO: enable when cross-lang is implemented
    buck2-graph = false; # TODO: enable when buck2 graph analysis is implemented
    verify-proofs = false; # Requires Lean4 toolchain
  };
}
