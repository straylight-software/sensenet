{
  description = "ℵ-0xFF — minimal viable nix: fmt, lint, buck2, remote";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix.url = "github:numtide/treefmt-nix";

    # LLVM 22 from git - required for nv toolchain
    llvm-project = {
      url = "github:llvm/llvm-project/bb1f220d534b0f6d80bea36662f5188ff11c2e54";
      flake = false;
    };

    # NativeLink - Local/Remote Execution for Buck2
    nativelink.url = "github:TraceMachina/nativelink";
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      imports = [ ./nix/modules/flake/_index.nix ];

      # Export overlays
      flake.overlays = (import ./nix/overlays inputs).flake.overlays;

      # Export modules for downstream flakes
      flake.flakeModules = {
        default = import ./nix/modules/flake/default.nix { inherit inputs; };
        formatter = import ./nix/modules/flake/formatter.nix { inherit inputs; };
        lint = ./nix/modules/flake/lint.nix;
        buck2 = ./nix/modules/flake/buck2.nix;
        build = ./nix/modules/flake/build/flake-module.nix;
        devshell = ./nix/modules/flake/devshell.nix;
        nativelink = ./nix/modules/flake/nativelink/flake-module.nix;
        std = import ./nix/modules/flake/std.nix { inherit inputs; };
      };

      # Export lib for downstream use
      flake.lib = import ./nix/lib { inherit (inputs.nixpkgs) lib; } // {
        buck2 = import ./nix/lib/buck2.nix { inherit inputs; };
      };

      # Export lint configs
      flake.lintConfigs = {
        clang-format = ./nix/configs/.clang-format;
        clang-tidy = ./nix/configs/.clang-tidy;
        ruff = ./nix/configs/ruff.toml;
        biome = ./nix/configs/biome.json;
        stylua = ./nix/configs/.stylua.toml;
        rustfmt = ./nix/configs/.rustfmt.toml;
        taplo = ./nix/configs/taplo.toml;
      };

      # Export lint rules
      flake.lintRules = ./linter/rules;

      # Export Dhall prelude
      flake.dhall = ./dhall;

      # Self-use: enable formatter for this repo
      perSystem = { pkgs, ... }: {
        packages.aleph-lint = pkgs.callPackage ./nix/packages/aleph-lint.nix { };
      };
    };
}
