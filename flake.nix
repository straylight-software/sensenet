{
  description = "sense/net — minimal viable nix: fmt, lint, sensenet, remote, typed";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix.url = "github:numtide/treefmt-nix";

    # LLVM 22 with SM120 Blackwell support - straylight fork
    llvm-project = {
      url = "github:straylight-software/llvm-project";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Buck2 prelude (straylight fork with NVIDIA support)
    buck2-prelude = {
      url = "github:weyl-ai/straylight-buck2-prelude";
      flake = false;
    };

    # NativeLink - Local/Remote Execution
    nativelink.url = "github:TraceMachina/nativelink";

    # ghc-source-gen from git (Hackage version doesn't support GHC 9.12)
    # Required for grapesy -> proto-lens-protoc -> ghc-source-gen
    ghc-source-gen-src = {
      url = "github:google/ghc-source-gen";
      flake = false;
    };

    # NVIDIA SDK - CUDA 13.1 runtime libraries (internal, dev branch)
    nvidia-sdk = {
      url = "git+ssh://git@github.com/straylight-software/nvidia-sdk.git?ref=dev";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.llvm-project.follows = "llvm-project";
    };

    # PureScript overlay - provides purs, spago-unstable, purs-backend-es
    purescript-overlay = {
      url = "github:thomashoneyman/purescript-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # nix-compile - Type inference and static analysis for Nix
    # TODO: Uncomment when repository is public
    # nix-compile = {
    #   url = "github:straylight-software/nix-compile";
    #   inputs.nixpkgs.follows = "nixpkgs";
    # };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      imports = [
        ./nix/modules/flake/_index.nix
        (import ./nix/modules/flake/sensenet/default.nix { inherit inputs; })
      ];

      # Export overlays
      flake.overlays = (import ./nix/overlays inputs).flake.overlays;

      # Export modules for downstream flakes
      flake.flakeModules = {
        default = import ./nix/modules/flake/default.nix { inherit inputs; };
        formatter = import ./nix/modules/flake/formatter.nix { inherit inputs; };
        lint = ./nix/modules/flake/lint.nix;
        # Primary: sensenet
        sensenet = import ./nix/modules/flake/sensenet/default.nix { inherit inputs; };
        # Backward compat: buck2 (deprecated, use sensenet)
        buck2 = import ./nix/modules/flake/sensenet/default.nix { inherit inputs; };
        buck2-old = ./nix/modules/flake/buck2.nix;
        build = ./nix/modules/flake/build/flake-module.nix;
        devshell = import ./nix/modules/flake/devshell.nix { inherit inputs; };
        nativelink = ./nix/modules/flake/nativelink/flake-module.nix;
        std = import ./nix/modules/flake/std.nix { inherit inputs; };
      };

      # Export lib for downstream use
      flake.lib = import ./nix/lib { inherit (inputs.nixpkgs) lib; } // {
        sensenet = import ./nix/lib/buck2.nix { inherit inputs; };
        # Backward compat
        buck2 = import ./nix/lib/buck2.nix { inherit inputs; };
      };

      # Lint configs exported by lint.nix module
      # Lint rules exported here (no module for this yet)
      flake.lintRules = ./linter/rules;

      # Export Dhall prelude
      flake.dhall = ./dhall;

      # Export NixOS modules
      flake.nixosModules = import ./nix/modules/nixos/_index.nix;

      # Self-use: packages and minimal devshell for this repo
      perSystem =
        { pkgs, ... }:
        let
          # GHC 9.12 with haskell overlay applied (via std.nix)
          inherit (pkgs.haskell.packages) ghc912;

          # Build sensenet CLI - use pre-generated nix expression
          sensenet = pkgs.callPackage ./nix/packages/sensenet.nix {
            inherit (ghc912)
              mkDerivation
              base
              bytestring
              containers
              dhall
              directory
              filepath
              process
              shelly
              temporary
              text
              unix
              ;
          };
        in
        {
          packages.sense-lint = pkgs.callPackage ./nix/packages/sense-lint.nix { };
          packages.sensenet = sensenet;

          # Declare examples as a Sensenet project
          sensenet.projects.examples = {
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
                ghcpackages = ghc912;
                packages = hp: [
                  hp.aeson
                  hp.bytestring
                  hp.containers
                  hp.dhall
                  hp.directory
                  hp.filepath
                  hp.process
                  hp.shelly
                  hp.temporary
                  hp.text
                  hp.unix
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
            remoteexecution = {
              enable = true;
              scheduler = "aleph-scheduler.fly.dev";
              schedulerport = 443;
              cas = "aleph-cas.fly.dev";
              casport = 443;
              tls = true;
              instancename = "main";
            };
            devshellpackages = [
              pkgs.ast-grep
              pkgs.cabal-install
              pkgs.dhall
              pkgs.dhall-json
              ghc912.haskell-language-server
              sensenet
            ];
          };

          # Example with NativeLink remote execution enabled
          # Usage: nix develop .#sensenet-examples-remote
          #        buck2 build --prefer-remote //src/examples/cxx:hello-cxx
          sensenet.projects.examples-remote = {
            src = ./.;
            targets = [
              "//src/examples/cxx:hello-cxx"
              "//src/examples/haskell:hello-hs"
              "//src/examples/rust:hello-rs"
              "//src/examples/lean:hello-lean"
            ];
            toolchain = {
              cxx.enable = true;
              haskell = {
                enable = true;
                ghcpackages = ghc912;
                packages = hp: [
                  hp.aeson
                  hp.bytestring
                  hp.containers
                  hp.text
                ];
              };
              rust.enable = true;
              lean.enable = true;
            };
            remoteexecution = {
              enable = true;
              scheduler = "aleph-scheduler.fly.dev";
              schedulerport = 443;
              cas = "aleph-cas.fly.dev";
              casport = 443;
              tls = true;
              instancename = "main";
            };
          };

        };
    };
}
