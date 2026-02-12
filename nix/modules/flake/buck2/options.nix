# nix/modules/flake/buck2/options.nix
#
# Options for declaring Buck2 projects within a flake.
#
# Usage:
#   buck2.projects.myproject = {
#     src = ./.;
#     targets = [ "//src/..." ];
#     toolchain.haskell.enable = true;
#     toolchain.haskell.packages = hp: [ hp.aeson hp.text ];
#   };
#
{ lib, flake-parts-lib, ... }:
{
  options.perSystem = flake-parts-lib.mkPerSystemOption (
    { pkgs, ... }:
    {
      options.buck2 = {
        projects = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                src = lib.mkOption {
                  type = lib.types.path;
                  description = "Source directory for the Buck2 project";
                };

                targets = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ "//..." ];
                  description = "Buck2 targets to build";
                };

                prelude = lib.mkOption {
                  type = lib.types.nullOr lib.types.path;
                  default = null;
                  description = "Path to Buck2 prelude (defaults to inputs.buck2-prelude)";
                };

                # ── Toolchain options ──────────────────────────────────────────────
                toolchain = {
                  # C++
                  cxx = {
                    enable = lib.mkEnableOption "C++ toolchain" // {
                      default = true;
                    };
                    llvmPackages = lib.mkOption {
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
                    ghcPackages = lib.mkOption {
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
                remoteExecution = {
                  enable = lib.mkEnableOption "NativeLink remote execution";

                  scheduler = lib.mkOption {
                    type = lib.types.str;
                    default = "localhost";
                    description = "Scheduler hostname (e.g., sense-scheduler.fly.dev)";
                  };

                  schedulerPort = lib.mkOption {
                    type = lib.types.port;
                    default = 50051;
                    description = "Scheduler gRPC port";
                  };

                  cas = lib.mkOption {
                    type = lib.types.str;
                    default = "localhost";
                    description = "CAS hostname (e.g., sense-cas.fly.dev)";
                  };

                  casPort = lib.mkOption {
                    type = lib.types.port;
                    default = 50052;
                    description = "CAS gRPC port";
                  };

                  tls = lib.mkOption {
                    type = lib.types.bool;
                    default = true;
                    description = "Use TLS for gRPC connections";
                  };

                  instanceName = lib.mkOption {
                    type = lib.types.str;
                    default = "main";
                    description = "RE instance name";
                  };
                };

                # ── Extra buckconfig sections ──────────────────────────────────────
                extraBuckconfigSections = lib.mkOption {
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
                extraPackages = lib.mkOption {
                  type = lib.types.listOf lib.types.package;
                  default = [ ];
                  description = "Additional packages for build and devshell";
                };

                devShellPackages = lib.mkOption {
                  type = lib.types.listOf lib.types.package;
                  default = [ ];
                  description = "Additional packages only for devshell";
                };

                devShellHook = lib.mkOption {
                  type = lib.types.lines;
                  default = "";
                  description = "Additional shell hook for development";
                };

                # ── Output options ─────────────────────────────────────────────────
                installBinaries = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Install executable binaries from buck-out";
                };

                installPhase = lib.mkOption {
                  type = lib.types.nullOr lib.types.lines;
                  default = null;
                  description = "Custom install phase";
                };
              };
            }
          );

          default = { };
          description = "Buck2 project definitions";
        };

        mkBuck2Project = lib.mkOption {
          type = lib.types.raw;
          readOnly = true;
          description = "Function to create a Buck2 project";
        };
      };
    }
  );
}
