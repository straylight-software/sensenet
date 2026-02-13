# nix/modules/flake/sensenet/options.nix
#
# Options for declaring Sensenet projects within a flake.
#
# Usage:
#   sensenet.projects.myproject = {
#     src = ./.;
#     targets = [ "//src/..." ];
#     toolchain.haskell.enable = true;
#     toolchain.haskell.packages = hp: [ hp.aeson hp.text ];
#   };
#
# Backward compatibility:
#   buck2.projects is aliased to sensenet.projects (deprecated)
#
{
  lib,
  flake-parts-lib,
  config,
  ...
}:
let
  # Project submodule - shared between sensenet and buck2 (backcompat)
  projectsubmodule =
    { pkgs }:
    lib.types.submodule {
      options = {
        src = lib.mkOption {
          type = lib.types.path;
          description = "Source directory for the project";
        };

        targets = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "//..." ];
          description = "Build targets";
        };

        prelude = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Path to prelude (defaults to inputs.buck2-prelude)";
        };

        # ── Toolchain options ──────────────────────────────────────────────
        toolchain = {
          # C++
          cxx = {
            enable = lib.mkEnableOption "C++ toolchain" // {
              default = true;
            };
            llvmpackages = lib.mkOption {
              type = lib.types.attrs;
              default = pkgs.llvmPackages_19;
              description = "LLVM packages to use";
            };
          };

          # Haskell
          haskell = {
            enable = lib.mkEnableOption "Haskell toolchain";
            packages = lib.mkOption {
              type = lib.types.raw;
              default = _hp: [ ];
              description = "Haskell packages function (hp: [ hp.aeson ... ])";
            };
            ghcpackages = lib.mkOption {
              type = lib.types.raw;
              default = pkgs.haskellPackages;
              description = "Haskell package set to use";
            };
          };

          # Rust
          rust = {
            enable = lib.mkEnableOption "Rust toolchain";
          };

          # Lean
          lean = {
            enable = lib.mkEnableOption "Lean toolchain";
          };

          # Python
          python = {
            enable = lib.mkEnableOption "Python toolchain";
            package = lib.mkOption {
              type = lib.types.package;
              default = pkgs.python312;
              description = "Python package to use";
            };
          };

          # CUDA/nv
          nv = {
            enable = lib.mkEnableOption "NVIDIA CUDA toolchain";
          };

          # PureScript
          purescript = {
            enable = lib.mkEnableOption "PureScript toolchain";
          };
        };

        # ── Remote Execution ────────────────────────────────────────────────
        remoteexecution = {
          enable = lib.mkEnableOption "NativeLink remote execution";

          scheduler = lib.mkOption {
            type = lib.types.str;
            default = "localhost";
            description = "Scheduler hostname (e.g., aleph-scheduler.fly.dev)";
          };

          schedulerport = lib.mkOption {
            type = lib.types.port;
            default = 50051;
            description = "Scheduler gRPC port";
          };

          cas = lib.mkOption {
            type = lib.types.str;
            default = "localhost";
            description = "CAS hostname (e.g., aleph-cas.fly.dev)";
          };

          casport = lib.mkOption {
            type = lib.types.port;
            default = 50052;
            description = "CAS gRPC port";
          };

          tls = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Use TLS for gRPC connections";
          };

          instancename = lib.mkOption {
            type = lib.types.str;
            default = "main";
            description = "RE instance name";
          };
        };

        # ── Extra buckconfig sections ──────────────────────────────────────
        extrabuckconfigsections = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = ''
            Extra content to append to .buckconfig.local.
            Use this for project-specific config like mdspan paths, shortlist, etc.
          '';
          example = ''
            [cxx]
            mdspan_include = ''${pkgs.mdspan}/include

            [shortlist]
            zlib_ng = ''${pkgs.zlib-ng}
          '';
        };

        # ── Extra packages ─────────────────────────────────────────────────
        extrapackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
          description = "Additional packages for build and devshell";
        };

        devshellpackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
          description = "Additional packages only for devshell";
        };

        devshellhook = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Additional shell hook for development";
        };

        # ── Output options ─────────────────────────────────────────────────
        installbinaries = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Install executable binaries from buck-out";
        };

        installphase = lib.mkOption {
          type = lib.types.nullOr lib.types.lines;
          default = null;
          description = "Custom install phase";
        };
      };
    };
in
{
  options.perSystem = flake-parts-lib.mkPerSystemOption (
    { pkgs, config, ... }:
    {
      # ── Primary: sensenet.projects ─────────────────────────────────────────
      options.sensenet = {
        projects = lib.mkOption {
          type = lib.types.attrsOf (projectsubmodule {
            inherit pkgs;
          });
          default = { };
          description = "Sensenet project definitions";
        };

        mkproject = lib.mkOption {
          type = lib.types.raw;
          "readOnly" = true;
          description = "Function to create a Sensenet project";
        };
      };

      # ── Backward compat: buck2.projects (deprecated) ───────────────────────
      options.buck2 = {
        projects = lib.mkOption {
          type = lib.types.attrsOf (projectsubmodule {
            inherit pkgs;
          });
          default = { };
          description = "DEPRECATED: Use sensenet.projects instead";
        };
      };

      # ── Merge buck2.projects into sensenet.projects ────────────────────────
      config.sensenet.projects = config.buck2.projects;
    }
  );
}
