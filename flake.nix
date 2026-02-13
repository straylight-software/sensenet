{
  description = "sense/net — minimal viable nix: fmt, lint, buck2, remote, typed";

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

    # Buck2 prelude (straylight fork with NVIDIA support)
    buck2-prelude = {
      url = "github:weyl-ai/straylight-buck2-prelude";
      flake = false;
    };

    # NativeLink - Local/Remote Execution for Buck2
    nativelink.url = "github:TraceMachina/nativelink";

    # ghc-source-gen from git (Hackage version doesn't support GHC 9.12)
    # Required for grapesy -> proto-lens-protoc -> ghc-source-gen
    ghc-source-gen-src = {
      url = "github:google/ghc-source-gen";
      flake = false;
    };

    # NVIDIA SDK - CUDA 13.0 runtime libraries for libtorch
    nvidia-sdk = {
      url = "github:weyl-ai/nvidia-sdk";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # nix-compile - Type inference and static analysis for Nix
    nix-compile = {
      url = "github:straylight-software/nix-compile";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Rust tooling for tokenizers-cpp
    crane.url = "github:ipetkov/crane";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      imports = [
        ./nix/modules/flake/_index.nix
        (import ./nix/modules/flake/buck2/default.nix { inherit inputs; })
      ];

      # Export overlays
      flake.overlays = (import ./nix/overlays inputs).flake.overlays;

      # Export modules for downstream flakes
      flake.flakeModules = {
        default = import ./nix/modules/flake/default.nix { inherit inputs; };
        formatter = import ./nix/modules/flake/formatter.nix { inherit inputs; };
        lint = ./nix/modules/flake/lint.nix;
        buck2 = import ./nix/modules/flake/buck2/default.nix { inherit inputs; };
        buck2-old = ./nix/modules/flake/buck2.nix;
        build = ./nix/modules/flake/build/flake-module.nix;
        devshell = ./nix/modules/flake/devshell.nix;
        nativelink = ./nix/modules/flake/nativelink/flake-module.nix;
        std = import ./nix/modules/flake/std.nix { inherit inputs; };
        # nix-compile integration - typed Nix analysis + proof obligations
        nix-compile = import ./nix/modules/flake/nix-compile/default.nix { inherit inputs; };
      };

      # Export lib for downstream use
      flake.lib = import ./nix/lib { inherit (inputs.nixpkgs) lib; } // {
        buck2 = import ./nix/lib/buck2.nix { inherit inputs; };
      };

      # Lint configs exported by lint.nix module
      # Lint rules exported here (no module for this yet)
      flake.lintRules = ./linter/rules;

      # Export Dhall prelude
      flake.dhall = ./dhall;

      # Self-use: packages and minimal devshell for this repo
      perSystem =
        { pkgs, system, ... }:
        let
          # GHC 9.12 with haskell overlay applied (via std.nix)
          inherit (pkgs.haskell.packages) ghc912;

          # Rust toolchain for tokenizers-cpp
          rustOverlays = [ (import inputs.rust-overlay) ];
          rustPkgs = import inputs.nixpkgs {
            inherit system;
            overlays = rustOverlays;
          };
          rustToolchain = rustPkgs.rust-bin.stable.latest.default;
          craneLib = (inputs.crane.mkLib rustPkgs).overrideToolchain rustToolchain;

          # tokenizers-cpp with pre-built Rust library
          tokenizers-cpp = pkgs.callPackage ./nix/packages/tokenizers-cpp.nix {
            inherit craneLib;
          };

        in
        {
          packages.sense-lint = pkgs.callPackage ./nix/packages/sense-lint.nix { };

          # Declare examples as a Buck2 project
          buck2.projects.examples = {
            src = ./.;
            targets = [
              "//src/examples/cxx:hello-cxx"
              "//src/examples/haskell:hello-hs"
              "//src/examples/rust:hello-rs"
              "//src/examples/lean:hello-lean"
              "//src/examples/purescript:halogen-todo"
              "//src/examples/blake:blake"
            ];
            toolchain = {
              cxx.enable = true;
              haskell = {
                enable = true;
                ghcPackages = ghc912;
                packages = hp: [
                  hp.aeson
                  hp.bytestring
                  hp.containers
                  hp.directory
                  hp.process
                  hp.text
                  hp.crypton
                  hp.memory
                  hp.hasktorch
                ];
              };
              rust.enable = true;
              lean.enable = true;
              python = {
                enable = true;
                package = pkgs.python3.withPackages (ps: [ ps.numpy ]);
              };
              nv.enable = true;
              purescript.enable = true;
            };
            remoteExecution = {
              enable = true;
              scheduler = "sense-scheduler.fly.dev";
              schedulerPort = 443;
              cas = "sense-cas.fly.dev";
              casPort = 443;
              tls = true;
              instanceName = "main";
            };
            devShellPackages = [
              pkgs.ast-grep
              pkgs.dhall
              pkgs.dhall-json
              ghc912.haskell-language-server
            ];
          };

          # ══════════════════════════════════════════════════════════════════════
          # slide - Console cowboy for the sprawl
          # ══════════════════════════════════════════════════════════════════════
          # Usage: nix develop .#buck2-slide
          #        buck2 build //src/slide:slide
          buck2.projects.slide = {
            src = ./.;
            targets = [ "//src/slide:slide" ];
            toolchain = {
              cxx.enable = true;
              haskell = {
                enable = true;
                ghcPackages = ghc912;
                packages = hp: [
                  # Core
                  hp.aeson
                  hp.async
                  hp.bytestring
                  hp.containers
                  hp.data-default-class
                  hp.text
                  hp.vector
                  # Parsing
                  hp.megaparsec
                  # Networking
                  hp.case-insensitive
                  hp.http2
                  hp.http-semantics
                  hp.http-types
                  hp.network
                  hp.time-manager
                  hp.tls
                  hp.wai
                  hp.warp
                  hp.zeromq4-haskell
                  # Config
                  hp.dhall
                  hp.optparse-applicative
                  # Crypto
                  hp.blake3
                  hp.crypton
                  hp.memory
                  # Observability
                  hp.katip
                  hp.prometheus-client
                  hp.prometheus-metrics-ghc
                  hp.random
                ];
              };
            };
            extraPackages = [
              tokenizers-cpp
              pkgs.zeromq
            ];
            extraBuckconfigSections = ''

              [slide]
              tokenizers_cpp_lib = ${tokenizers-cpp}/lib
              tokenizers_cpp_include = ${tokenizers-cpp}/include
            '';
            devShellPackages = [
              pkgs.dhall
              pkgs.dhall-json
              ghc912.haskell-language-server
            ];
            devShellHook = ''
              export LIBRARY_PATH="${tokenizers-cpp}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"
              export C_INCLUDE_PATH="${tokenizers-cpp}/include''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
              export LD_LIBRARY_PATH="${tokenizers-cpp}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            '';
          };

          # Example with NativeLink remote execution enabled
          # Usage: nix develop .#buck2-examples-remote
          #        buck2 build --prefer-remote //src/examples/cxx:hello-cxx
          buck2.projects.examples-remote = {
            src = ./.;
            targets = [
              "//src/examples/cxx:hello-cxx"
              "//src/examples/haskell:hello-hs"
              "//src/examples/rust:hello-rs"
            ];
            toolchain = {
              cxx.enable = true;
              haskell = {
                enable = true;
                ghcPackages = ghc912;
                packages = hp: [
                  hp.aeson
                  hp.bytestring
                  hp.containers
                  hp.text
                ];
              };
              rust.enable = true;
            };
            remoteExecution = {
              enable = true;
              scheduler = "sense-scheduler.fly.dev";
              schedulerPort = 443;
              cas = "sense-cas.fly.dev";
              casPort = 443;
              tls = true;
              instanceName = "main";
            };
          };

        };
    };
}
