# nix/modules/flake/sensenet/flake-module.nix
#
# Flake module for declaring Sensenet projects.
#
# Creates:
#   - packages.sensenet-<name>: Nix derivation that builds the targets
#   - devShells.sensenet-<name>: Development shell with toolchains configured
#
# Backward compatibility:
#   - packages.buck2-<name> and devShells.buck2-<name> are also created (deprecated)
#
# The package derivation runs buck2 build with __noChroot = true, allowing
# it to use the buck2 daemon and cache.
#
{ inputs, ... }:
{
  _class = "flake";

  imports = [ ./options.nix ];

  config.perSystem =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      toolchainlib = import ./toolchains.nix { inherit lib pkgs; };

      # Import centralized render-dhall function
      render-dhall = import ../../../lib/render-dhall.nix { inherit pkgs lib; };

      # Scripts directory for Dhall templates
      scripts-dir = ./scripts;

      mkproject =
        {
          name,
          src,
          targets ? [ "//..." ],
          prelude ? null,
          toolchain ? { },
          remoteexecution ? { },
          extrabuckconfigsections ? "",
          extrapackages ? [ ],
          devshellpackages ? [ ],
          devshellhook ? "",
          installbinaries ? true,
          installphase ? null,
          ...
        }:
        let
          # ── Resolve toolchain packages ─────────────────────────────────────────
          cxxenabled = toolchain.cxx.enable or true;
          haskellenabled = toolchain.haskell.enable or false;
          rustenabled = toolchain.rust.enable or false;
          leanenabled = toolchain.lean.enable or false;
          pythonenabled = toolchain.python.enable or false;
          nvenabled = toolchain.nv.enable or false;
          purescriptenabled = toolchain.purescript.enable or false;

          # ── Remote execution config ────────────────────────────────────────────
          reenabled = remoteexecution.enable or false;
          rescheduler = remoteexecution.scheduler or "localhost";
          reschedulerport = remoteexecution.schedulerport or 50051;
          recas = remoteexecution.cas or "localhost";
          recasport = remoteexecution.casport or 50052;
          retls = remoteexecution.tls or true;
          reinstancename = remoteexecution.instancename or "main";

          llvmpackages = toolchain.cxx.llvmpackages or pkgs.llvmPackages_19;
          hspackages = toolchain.haskell.ghcpackages or pkgs.haskellPackages;
          hspkgsfn = toolchain.haskell.packages or (_hp: [ ]);
          ghcversion = hspackages.ghc.version;
          ghc = hspackages.ghcWithPackages hspkgsfn;
          # Stan static analysis tool for Haskell
          inherit (hspackages) stan;
          # hoogleWithPackages builds a hoogle with pre-generated database for our packages
          hooglewithdb = hspackages.hoogleWithPackages hspkgsfn;
          python = toolchain.python.package or pkgs.python312;
          inherit (pkgs.python3Packages) pybind11;
          # Only evaluate nvidia-sdk when nv toolchain is enabled
          nvidia-sdk = if nvenabled && pkgs ? nvidia-sdk then pkgs.nvidia-sdk else null;

          # ── Generate buckconfig.local ──────────────────────────────────────────
          buckconfiglocal = toolchainlib.mkBuckconfigLocal {
            cxx = lib.optionalString cxxenabled (toolchainlib.mkCxxSection { llvmPackages = llvmpackages; });
            haskell = lib.optionalString haskellenabled (
              toolchainlib.mkHaskellSection {
                inherit ghc stan;
                ghcVersion = ghcversion;
                # ghc-pkg-id wrapper for GHC 9.12 -package workaround
                ghcPkgWrapper = "${inputs.self}/toolchains/scripts/ghc-pkg-id";
              }
            );
            rust = lib.optionalString rustenabled (toolchainlib.mkRustSection { });
            lean = lib.optionalString leanenabled (toolchainlib.mkLeanSection { });
            python = lib.optionalString pythonenabled (
              toolchainlib.mkPythonSection { inherit python pybind11; }
            );
            nv = lib.optionalString (nvidia-sdk != null) (
              toolchainlib.mkNvSection {
                inherit nvidia-sdk;
                inherit (llvmpackages) clang-unwrapped;

                # mdspan from nixpkgs (Kokkos reference implementation)
                mdspan = pkgs.callPackage "${inputs.self}/nix/packages/mdspan.nix" { };
              }
            );
            purescript = lib.optionalString purescriptenabled (toolchainlib.mkPureScriptSection { });
            remoteExecution = lib.optionalString reenabled (
              toolchainlib.mkRemoteExecutionSection {
                scheduler = rescheduler;
                schedulerPort = reschedulerport;
                cas = recas;
                casPort = recasport;
                tls = retls;
                instanceName = reinstancename;
              }
            );
            extra = extrabuckconfigsections;
          };

          buckconfiglocalfile = pkgs.writeText "buckconfig.local" buckconfiglocal;

          # ── Prelude path ───────────────────────────────────────────────────────
          preludepath = if prelude != null then prelude else inputs.buck2-prelude;

          # ── Toolchain packages ─────────────────────────────────────────────────
          toolchainpackages = [
            pkgs.buck2
          ]
          ++ lib.optionals cxxenabled [
            llvmpackages.clang
            llvmpackages.lld
            llvmpackages.llvm
          ]
          ++ lib.optionals haskellenabled [
            ghc
            hspackages.haskell-language-server
            hooglewithdb # hoogle with pre-built database for project packages
          ]
          ++ lib.optionals rustenabled [
            pkgs.rustc
            pkgs.cargo
            pkgs.clippy
            pkgs.rustfmt
            pkgs.rust-analyzer
          ]
          ++ lib.optionals leanenabled [ pkgs.lean4 ]
          ++ lib.optionals pythonenabled [ python ]
          ++ lib.optionals purescriptenabled [
            pkgs.purescript
            pkgs.spago
            pkgs.nodejs
          ]
          ++ extrapackages;

          # ── Configs path (from inputs.self) ──────────────────────────────────
          configspath = inputs.self + "/nix/configs";

          # ── Shell hook ─────────────────────────────────────────────────────────
          shellhooktemplate = builtins.readFile ./shell-hook.bash;

          # Toolchains path (from inputs.self)
          toolchainspath = inputs.self + "/toolchains";

          shellhook =
            builtins.replaceStrings
              [
                "@name@"
                "@reEnabled@"
                "@reScheduler@"
                "@reSchedulerPort@"
                "@haskellEnabled@"
                "@ghcBin@"
                "@preludePath@"
                "@toolchainsPath@"
                "@buckconfigLocalFile@"
                "@configsPath@"
                "@cxxEnabled@"
                "@nvEnabled@"
                "@nvSdkLib@"
                "@targets@"
                "@devshellhook@"
              ]
              [
                name
                (lib.optionalString reenabled "true")
                rescheduler
                (toString reschedulerport)
                (lib.optionalString haskellenabled "true")
                "${ghc}/bin"
                (toString preludepath)
                (toString toolchainspath)
                (toString buckconfiglocalfile)
                (toString configspath)
                (lib.optionalString cxxenabled "true")
                (lib.optionalString (nvenabled && nvidia-sdk != null) "true")
                (lib.optionalString (nvenabled && nvidia-sdk != null) "${nvidia-sdk}/lib")
                (lib.concatStringsSep " " targets)
                devshellhook
              ]
              shellhooktemplate;

          # ── Package derivation ─────────────────────────────────────────────────
          package = pkgs.stdenvNoCC.mkDerivation {
            inherit name;
            inherit src;

            __noChroot = true; # Allow buck2 daemon access

            nativeBuildInputs = toolchainpackages ++ [
              pkgs.git
              pkgs.cacert
            ];

            buildPhase =
              let
                buildPhaseScript = render-dhall "build-phase" (scripts-dir + "/build-phase.dhall") {
                  prelude-path = preludepath;
                  buckconfig-local-file = buckconfiglocalfile;
                  targets = lib.concatStringsSep " " targets;
                };
              in
              builtins.readFile buildPhaseScript;

            installPhase =
              if installphase != null then
                installphase
              else
                let
                  installPhaseScript = render-dhall "install-phase" (scripts-dir + "/install-phase.dhall") {
                    install-binaries = if installbinaries then "1" else "0";
                    targets = lib.concatStringsSep " " targets;
                  };
                in
                builtins.readFile installPhaseScript;

            "dontConfigure" = true;
            "dontFixup" = true;

            meta = {
              description = "Sense/Net build package for ${name}";
              license = lib.licenses.mit;
            };
          };

          # ── Development shell ──────────────────────────────────────────────────
          devshell = pkgs.mkShellNoCC {
            name = "${name}-dev";

            inputsFrom = [ package ];
            packages = devshellpackages ++ [
              pkgs.jq
              pkgs.ripgrep
              pkgs.fd
            ];

            shellHook = shellhook;
          };
        in
        {
          inherit package devshell buckconfiglocalfile;
        };

      # ── Build all declared projects ──────────────────────────────────────────
      # sensenet.projects is the primary source (includes merged buck2.projects)
      sensenetprojects = lib.mapAttrs (
        name: proj: mkproject (proj // { inherit name; })
      ) config.sensenet.projects;
    in
    {
      # ── Primary: sensenet.mkproject ──────────────────────────────────────────
      sensenet.mkproject = mkproject;

      # ── Primary outputs: sensenet-<name> ─────────────────────────────────────
      packages =
        lib.mapAttrs' (name: proj: lib.nameValuePair "sensenet-${name}" proj.package) sensenetprojects
        # Backward compat: buck2-<name> (deprecated)
        // lib.mapAttrs' (name: proj: lib.nameValuePair "buck2-${name}" proj.package) sensenetprojects;

      devShells =
        lib.mapAttrs' (name: proj: lib.nameValuePair "sensenet-${name}" proj.devshell) sensenetprojects
        # Backward compat: buck2-<name> (deprecated)
        // lib.mapAttrs' (name: proj: lib.nameValuePair "buck2-${name}" proj.devshell) sensenetprojects;
    };
}
