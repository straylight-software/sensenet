# nix/modules/flake/buck2/flake-module.nix
#
# Flake module for declaring Buck2 projects.
#
# Creates:
#   - packages.buck2-<name>: Nix derivation that builds the Buck2 targets
#   - devShells.buck2-<name>: Development shell with toolchains configured
#
# The package derivation runs buck2 build with __noChroot = true, allowing
# it to use the buck2 daemon and cache.
#
{ inputs, ... }:
{
  imports = [ ./options.nix ];

  config.perSystem =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      toolchainLib = import ./toolchain.nix { inherit lib pkgs; };

      mkBuck2Project =
        {
          name,
          src,
          targets ? [ "//..." ],
          prelude ? null,
          toolchain ? { },
          remoteExecution ? { },
          extraBuckconfigSections ? "",
          extraPackages ? [ ],
          devShellPackages ? [ ],
          devShellHook ? "",
          installBinaries ? true,
          installPhase ? null,
          ...
        }:
        let
          # ── Resolve toolchain packages ─────────────────────────────────────────
          cxxEnabled = toolchain.cxx.enable or true;
          haskellEnabled = toolchain.haskell.enable or false;
          rustEnabled = toolchain.rust.enable or false;
          leanEnabled = toolchain.lean.enable or false;
          pythonEnabled = toolchain.python.enable or false;
          nvEnabled = toolchain.nv.enable or false;

          # ── Remote execution config ────────────────────────────────────────────
          reEnabled = remoteExecution.enable or false;
          reScheduler = remoteExecution.scheduler or "localhost";
          reSchedulerPort = remoteExecution.schedulerPort or 50051;
          reCas = remoteExecution.cas or "localhost";
          reCasPort = remoteExecution.casPort or 50052;
          reTls = remoteExecution.tls or true;
          reInstanceName = remoteExecution.instanceName or "main";

          llvmPackages = toolchain.cxx.llvmPackages or pkgs.llvmPackages_19;
          hsPackages = toolchain.haskell.ghcPackages or pkgs.haskellPackages;
          hsPkgsFn = toolchain.haskell.packages or (_hp: [ ]);
          ghcVersion = hsPackages.ghc.version;
          ghc = hsPackages.ghcWithPackages hsPkgsFn;
          # hoogleWithPackages builds a hoogle with pre-generated database for our packages
          hoogleWithDb = hsPackages.hoogleWithPackages hsPkgsFn;
          python = toolchain.python.package or pkgs.python312;
          nvidia-sdk = pkgs.nvidia-sdk or null;

          # ── Generate buckconfig.local ──────────────────────────────────────────
          buckconfigLocal = toolchainLib.mkBuckconfigLocal {
            cxx = lib.optionalString cxxEnabled (toolchainLib.mkCxxSection { inherit llvmPackages; });
            haskell = lib.optionalString haskellEnabled (
              toolchainLib.mkHaskellSection { inherit ghc ghcVersion; }
            );
            rust = lib.optionalString rustEnabled (toolchainLib.mkRustSection { });
            lean = lib.optionalString leanEnabled (toolchainLib.mkLeanSection { });
            python = lib.optionalString pythonEnabled (toolchainLib.mkPythonSection { inherit python; });
            nv = lib.optionalString (nvEnabled && nvidia-sdk != null) (
              toolchainLib.mkNvSection {
                inherit nvidia-sdk;
                inherit (llvmPackages) clang-unwrapped;

                # mdspan from nixpkgs (Kokkos reference implementation)
                mdspan = pkgs.callPackage "${inputs.self}/nix/packages/mdspan.nix" { };
              }
            );
            remoteExecution = lib.optionalString reEnabled (
              toolchainLib.mkRemoteExecutionSection {
                scheduler = reScheduler;
                schedulerPort = reSchedulerPort;
                cas = reCas;
                casPort = reCasPort;
                tls = reTls;
                instanceName = reInstanceName;
              }
            );
            extra = extraBuckconfigSections;
          };

          buckconfigLocalFile = pkgs.writeText "buckconfig.local" buckconfigLocal;

          # ── Prelude path ───────────────────────────────────────────────────────
          preludePath = if prelude != null then prelude else inputs.buck2-prelude;

          # ── Toolchain packages ─────────────────────────────────────────────────
          toolchainPackages = [
            pkgs.buck2
          ]
          ++ lib.optionals cxxEnabled [
            llvmPackages.clang
            llvmPackages.lld
            llvmPackages.llvm
          ]
          ++ lib.optionals haskellEnabled [
            ghc
            hsPackages.haskell-language-server
            hoogleWithDb # hoogle with pre-built database for project packages
          ]
          ++ lib.optionals rustEnabled [
            pkgs.rustc
            pkgs.cargo
            pkgs.clippy
            pkgs.rustfmt
            pkgs.rust-analyzer
          ]
          ++ lib.optionals leanEnabled [ pkgs.lean4 ]
          ++ lib.optionals pythonEnabled [ python ]
          ++ extraPackages;

          # ── Configs path (from inputs.self) ──────────────────────────────────
          configsPath = inputs.self + "/nix/configs";

          # ── Shell hook ─────────────────────────────────────────────────────────
          shellHookTemplate = builtins.readFile ./shell-hook.bash;

          shellHook =
            builtins.replaceStrings
              [
                "@name@"
                "@reEnabled@"
                "@reScheduler@"
                "@reSchedulerPort@"
                "@haskellEnabled@"
                "@ghcBin@"
                "@preludePath@"
                "@buckconfigLocalFile@"
                "@configsPath@"
                "@cxxEnabled@"
                "@targets@"
                "@devShellHook@"
              ]
              [
                name
                (lib.optionalString reEnabled "true")
                reScheduler
                (toString reSchedulerPort)
                (lib.optionalString haskellEnabled "true")
                "${ghc}/bin"
                (toString preludePath)
                (toString buckconfigLocalFile)
                (toString configsPath)
                (lib.optionalString cxxEnabled "true")
                (lib.concatStringsSep " " targets)
                devShellHook
              ]
              shellHookTemplate;

          # ── Package derivation ─────────────────────────────────────────────────
          package = pkgs.stdenvNoCC.mkDerivation {
            inherit name;
            inherit src;

            __noChroot = true; # Allow buck2 daemon access

            nativeBuildInputs = toolchainPackages ++ [
              pkgs.git
              pkgs.cacert
            ];

            buildPhase = ''
              export HOME=$TMPDIR

              # Set up prelude
              mkdir -p nix/build
              ln -sf ${preludePath} nix/build/prelude

              # Generate buckconfig.local
              cp ${buckconfigLocalFile} .buckconfig.local

              # Build targets
              buck2 build ${lib.concatStringsSep " " targets}
            '';

            installPhase =
              if installPhase != null then
                installPhase
              else
                ''
                  mkdir -p $out

                  ${lib.optionalString installBinaries ''
                    mkdir -p $out/bin
                    find buck-out/v2/gen -type f -executable -not -name "*.so" -not -name "*.a" 2>/dev/null | while read bin; do
                      if file "$bin" | grep -q "ELF.*executable"; then
                        install -m 755 "$bin" "$out/bin/" 2>/dev/null || true
                      fi
                    done
                  ''}

                  # Always create a marker file
                  echo "${lib.concatStringsSep " " targets}" > $out/.buck2-targets
                '';

            dontConfigure = true;
            dontFixup = true;
          };

          # ── Development shell ──────────────────────────────────────────────────
          devShell = pkgs.mkShellNoCC {
            name = "${name}-dev";

            inputsFrom = [ package ];
            packages = devShellPackages ++ [
              pkgs.jq
              pkgs.ripgrep
              pkgs.fd
            ];

            inherit shellHook;
          };
        in
        {
          inherit package devShell buckconfigLocalFile;
        };

      # ── Build all declared projects ──────────────────────────────────────────
      buck2Projects = lib.mapAttrs (
        name: proj: mkBuck2Project (proj // { inherit name; })
      ) config.buck2.projects;
    in
    {
      buck2.mkBuck2Project = mkBuck2Project;

      packages = lib.mapAttrs' (name: proj: lib.nameValuePair "buck2-${name}" proj.package) buck2Projects;

      devShells = lib.mapAttrs' (
        name: proj: lib.nameValuePair "buck2-${name}" proj.devShell
      ) buck2Projects;
    };
}
