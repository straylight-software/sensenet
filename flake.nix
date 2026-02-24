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

    # Crane - Rust build tool for Nix
    crane.url = "github:ipetkov/crane";

    # Rust overlay for toolchain selection
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # nix2gpu - OCI container builder for Nix
    nix2gpu.url = "github:fleek-sh/nix2gpu";

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

          # Minimal deps required by sensenet.cabal
          sensenetDeps = {
            inherit (ghc912)
              mkDerivation
              aeson
              async
              base
              bytestring
              containers
              crypton
              deepseq
              dhall
              directory
              either
              filepath
              hashable
              hostname
              katip
              memory
              microlens
              process
              text
              text-short
              time
              unix
              unordered-containers
              vector
              ;
          };

          # Stage 1: Bootstrap - minimal deps, fast build
          sensenet-bootstrap = pkgs.callPackage ./nix/packages/sensenet-bootstrap.nix sensenetDeps;

          # Stage 2: Local - same as bootstrap (no remote execution deps)
          sensenet-local = pkgs.callPackage ./nix/packages/sensenet-local.nix sensenetDeps;

          # Stage 3: Full - all features (currently same as local)
          sensenet = pkgs.callPackage ./nix/packages/sensenet.nix sensenetDeps;
        in
        {
          packages.sense-lint = pkgs.callPackage ./nix/packages/sense-lint.nix { };

          # 3-stage bootstrap flow:
          # 1. nix build .#sensenet-bootstrap  (minimal, fast)
          # 2. nix build .#sensenet-local      (local-only features)
          # 3. nix build .#sensenet            (full, all features)
          packages.sensenet-bootstrap = sensenet-bootstrap;
          packages.sensenet-local = sensenet-local;
          packages.sensenet = sensenet;

          # Static binary using pkgsStatic (musl-based)
          packages.sensenet-static = import ./nix/packages/sensenet-static.nix {
            inherit (pkgs) lib;
            pkgsMusl = pkgs.pkgsStatic;
          };

          # ════════════════════════════════════════════════════════════════════════
          #                                                      // nix // flake // check
          # ════════════════════════════════════════════════════════════════════════
          #
          # Run with: nix flake check
          #
          # This runs ALL checks:
          #   1. sensenet-tests: CLI smoke tests
          #   2. sensenet-haskell: cabal test suite (unit + property tests)
          #   3. treefmt: formatting (includes straylight-haskell-lint)
          #
          # ════════════════════════════════════════════════════════════════════════

          # ── CLI smoke tests ──────────────────────────────────────────────────────
          checks.sensenet-tests = pkgs.stdenv.mkDerivation {
            name = "sensenet-tests";
            src = pkgs.lib.cleanSource ./.;
            nativeBuildInputs = [
              sensenet
              pkgs.bash
              pkgs.gnugrep
              pkgs.coreutils
              pkgs.glibcLocales
            ];
            buildPhase = ''
              # Set up UTF-8 locale for Unicode output
              export LANG=en_US.UTF-8
              export LC_ALL=en_US.UTF-8
              export LOCALE_ARCHIVE="${pkgs.glibcLocales}/lib/locale/locale-archive"

              # Set up environment
              export HOME=$TMPDIR
              export PATH="${sensenet}/bin:$PATH"
              cp ${sensenet}/bin/sensenet ./sense
              chmod +x ./sense

              # Run quick test suite (CLI only, no build tests)
              export SENSENET_QUICK_TEST=1
              bash ./scripts/test-all.sh
            '';
            installPhase = ''
              mkdir -p $out
              echo "All tests passed" > $out/result.txt
            '';
          };

          # ── Haskell unit + property tests ────────────────────────────────────────
          # NOTE: Disabled in nix flake check because cabal needs network to fetch
          # packages in the Nix sandbox. Run tests locally via:
          #   nix develop -c cabal test
          # or:
          #   ./scripts/test-all.sh
          #
          # TODO: Use haskell.nix or cabal2nix for proper pure Nix Haskell builds
          #
          # checks.sensenet-haskell = pkgs.stdenv.mkDerivation { ... };

          # ── Style guide enforcement ──────────────────────────────────────────────
          # Note: THE GUARD MANDATE and other style rules are enforced by
          # treefmt via straylight-haskell-lint. Run `nix fmt` to check/fix.

          # Full integration tests - run locally with ./scripts/test-all.sh
          # These require the full dev environment with toolchains
          # Not included in nix flake check because sandbox lacks toolchain paths

          # Convenience app to run tests: nix run .#test
          packages.test = pkgs.writeShellScriptBin "sensenet-test" ''
            export PATH="${sensenet}/bin:$PATH"
            exec bash ${pkgs.lib.cleanSource ./.}/scripts/test-all.sh
          '';

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
              # Static linking libs for sensenet binary
              pkgs.glibc.static
              pkgs.zlib.static
              pkgs.gmp.static
              pkgs.libffi
              pkgs.numactl
              (pkgs.ncurses.override { enableStatic = true; })
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
