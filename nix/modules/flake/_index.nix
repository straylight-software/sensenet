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
    (import ./devshell.nix { inherit inputs; })
    (import ./std.nix { inherit inputs; })
    (import ./nix-compile/default.nix { inherit inputs; })
    # nix2gpu must be imported before nativelink (provides container building)
    inputs.nix2gpu.flakeModule
    (import ./nativelink/flake-module.nix { inherit inputs; })
  ];

  # Enable devshell for this repo
  # NOTE: sensenet.build.enable requires scripts/ directory which is missing
  sensenet.devshell.enable = true;
  sensenet.devshell.nv.enable = true;

  # Enable custom LLVM git toolchain for SM120 support
  sensenet.llvm-git.enable = true;

  # Enable NativeLink remote execution (GCP aarch64)
  sensenet.nativelink = {
    enable = true;
    provider = "gcp";
    app-prefix = "sensenet";
    gcp = {
      project = "straylight-486401";
      zone = "us-central1-a";
      worker-machine-type = "t2a-standard-4"; # Start small for testing
    };
  };

  # PureScript overlay for purs, spago-unstable
  sensenet.nixpkgs.overlays = [ inputs.purescript-overlay.overlays.default ];

  # Enable nix-compile static analysis
  # TODO: Enable when nix-compile input is uncommented in flake.nix
  sensenet.nix-compile = {
    enable = false; # requires inputs.nix-compile
    profile = "strict";
    verify-dhall = true;
    cross-language = false; # TODO: enable when cross-lang is implemented
    buck2-graph = false; # TODO: enable when buck2 graph analysis is implemented
    verify-proofs = false; # Requires Lean4 toolchain
  };
}
