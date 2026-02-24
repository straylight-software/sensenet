# nix/modules/flake/formatter.nix
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                                                         // formatter // module
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
#     "Case's virus had bored a window through the library's command ice.
#      He punched himself through and found an address."
#
#                                                               — Neuromancer
#
# Treefmt integration. Unified formatting and linting across all languages.
#
# Pipeline for C/C++:
#   1. clang-format (mechanical layout, rewrites files)
#   2. clang-tidy (semantic lint, warnings-as-errors)
#   3. cppcheck (deep flow analysis)
#   4. sense-grep (straylight-specific AST patterns)
#
# See: docs/guidelines/03-cpp.md for rationale.
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{ inputs }:
{ config, lib, ... }:
let
  cfg = config.sense.formatter;

  # ──────────────────────────────────────────────────────────────────────────
  #                                                        // cpp // file // patterns
  # ──────────────────────────────────────────────────────────────────────────

  cpp-includes = [
    "*.c"
    "*.h"
    "*.cpp"
    "*.hpp"
    "*.cc"
    "*.hh"
    "*.cxx"
    "*.hxx"
    "*.cu"
    "*.cuh"
  ];

in
{
  _class = "flake";
  imports = [ inputs.treefmt-nix.flakeModule ];

  # ════════════════════════════════════════════════════════════════════════════
  #                                                                   // options
  # ════════════════════════════════════════════════════════════════════════════

  options.sense.formatter = {
    enable = lib.mkEnableOption "sense formatter" // {
      default = true;
    };

    indent-width = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "Indent width in spaces";
    };

    line-length = lib.mkOption {
      type = lib.types.int;
      default = 100;
      description = "Maximum line length";
    };

    enable-check = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable flake check for treefmt";
    };

    # ──────────────────────────────────────────────────────────────────────────
    #                                                    // haskell // options
    # ──────────────────────────────────────────────────────────────────────────

    haskell = {
      enable-style-lint = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Enable straylight Haskell style linting.
          Enforces THE GUARD MANDATE and other conventions from HASKELL_STYLE_GUIDE.md
        '';
      };
    };

    # ──────────────────────────────────────────────────────────────────────────
    #                                                        // cpp // options
    # ──────────────────────────────────────────────────────────────────────────

    cpp = {
      enable-clang-tidy = lib.mkOption {
        type = lib.types.bool;
        # TODO: Re-enable once clang-tidy is integrated into Buck2 build.
        # Disabled - compile_commands.json has absolute paths that don't exist
        # in Nix sandbox. Will run as part of buck2 build //src:lint instead.
        default = false;
        description = "Enable clang-tidy semantic linting";
      };

      enable-cppcheck = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable cppcheck flow analysis";
      };

      enable-sense-grep = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable sense-grep AST pattern checks";
      };

      compile-commands-path = lib.mkOption {
        type = lib.types.str;
        default = "compile_commands.json";
        description = "Path to compile_commands.json for clang-tidy";
      };
    };
  };

  # ════════════════════════════════════════════════════════════════════════════
  #                                                                    // config
  # ════════════════════════════════════════════════════════════════════════════

  config = lib.mkIf cfg.enable {
    perSystem =
      { pkgs, system, ... }:
      let
        # ────────────────────────────────────────────────────────────────────────
        #                                                      // llvm // toolchain
        # ────────────────────────────────────────────────────────────────────────
        #
        # Use our custom LLVM 22 from git for clang-format (stable).
        # Use nixpkgs llvmPackages_19 for clang-tidy (LLVM 22 git has bugs).
        #
        # ────────────────────────────────────────────────────────────────────────

        llvm-format-pkg = pkgs.llvm-git or pkgs.llvmPackages_19.clang-tools;
        llvm-tidy-pkg = pkgs.llvmPackages_19.clang-tools;

        # ────────────────────────────────────────────────────────────────────────
        #                                                   // clang-tidy // wrapper
        # ────────────────────────────────────────────────────────────────────────

        clang-tidy-wrapper = pkgs.writeShellApplication {
          name = "clang-tidy-check";
          runtimeInputs = [ ];
          text = ''
            export COMPILE_COMMANDS_PATH="${cfg.cpp.compile-commands-path}"
            export CLANG_TIDY_BIN="${llvm-tidy-pkg}/bin/clang-tidy"
            export CLANG_TIDY_CONFIG="${../../configs/.clang-tidy}"
            ${builtins.readFile ./scripts/clang-tidy-check.sh}
          '';
        };

        # ────────────────────────────────────────────────────────────────────────
        #                                                     // cppcheck // wrapper
        # ────────────────────────────────────────────────────────────────────────

        cppcheck-wrapper = pkgs.writeShellApplication {
          name = "cppcheck-check";
          runtimeInputs = [ ];
          text = ''
            export CPPCHECK_BIN="${pkgs.cppcheck}/bin/cppcheck"
            ${builtins.readFile ./scripts/cppcheck-check.sh}
          '';
        };

        # ────────────────────────────────────────────────────────────────────────
        #                                                   // sense-grep // wrapper
        # ────────────────────────────────────────────────────────────────────────
        #
        # n.b. ast-grep --rule takes a single file, so we run each rule separately
        # and exit on first failure
        #
        # ────────────────────────────────────────────────────────────────────────

        sense-grep-cpp-wrapper = pkgs.writeShellApplication {
          name = "sense-grep-cpp";
          runtimeInputs = [ ];
          text = ''
            export RULES_DIR="${inputs.self}/linter/rules"
            export AST_GREP_BIN="${pkgs.ast-grep}/bin/ast-grep"
            ${builtins.readFile ./scripts/sense-grep-cpp.sh}
          '';
        };

        # ────────────────────────────────────────────────────────────────────────
        #                                                  // haskell // lint // wrapper
        # ────────────────────────────────────────────────────────────────────────
        #
        # Enforces THE GUARD MANDATE and other straylight Haskell conventions.
        # See: HASKELL_STYLE_GUIDE.md
        #
        # ────────────────────────────────────────────────────────────────────────

        haskell-lint-wrapper = pkgs.writeShellApplication {
          name = "straylight-haskell-lint";
          runtimeInputs = [
            pkgs.bash
            pkgs.gnugrep
            pkgs.gnused
            pkgs.coreutils
          ];
          text = builtins.readFile ./scripts/haskell-lint.sh;
        };

      in
      {
        treefmt = {
          projectRootFile = "flake.nix";

          # ────────────────────────────────────────────────────────────────────────
          #                                                       // global // excludes
          # ────────────────────────────────────────────────────────────────────────
          #
          # Exclude generated files, build outputs, and vendored code from all
          # formatters. These are either machine-generated or third-party.
          #
          # ────────────────────────────────────────────────────────────────────────

          settings.global.excludes = [
            # Build outputs
            "sensenet-out/*"
            "buck-out/*"
            "result"
            "result-*"
            "dist-newstyle/*"

            # Generated PureScript output
            "**/output/*"
            "**/output-test/*"

            # Vendored third-party code
            "vendor/*"

            # Node modules
            "**/node_modules/*"

            # Generated toolchain files
            ".sensenet/toolchains.json"

            # Spago cache
            "**/.spago/*"
          ];

          # ────────────────────────────────────────────────────────────────────────
          #                                                            // nix // lint
          # ────────────────────────────────────────────────────────────────────────

          programs.nixfmt.enable = true;

          programs.deadnix = {
            enable = true;
            excludes = [ "nix/templates/*" ];
          };

          programs.statix.enable = true;

          # ────────────────────────────────────────────────────────────────────────
          #                                                          // shell // lint
          # ────────────────────────────────────────────────────────────────────────

          programs.shfmt = {
            enable = true;
            "indent_size" = cfg.indent-width;
          };

          # ────────────────────────────────────────────────────────────────────────
          #                                                         // python // lint
          # ────────────────────────────────────────────────────────────────────────

          programs.ruff-format = {
            enable = true;
            "lineLength" = cfg.line-length;
          };

          programs.ruff-check.enable = true;

          # ────────────────────────────────────────────────────────────────────────
          #                                                            // cpp // lint
          # ────────────────────────────────────────────────────────────────────────

          programs.clang-format = {
            enable = true;
            package = llvm-format-pkg;
            includes = cpp-includes ++ [ "*.proto" ];
          };

          # ────────────────────────────────────────────────────────────────────────
          #                                                             // js // lint
          # ────────────────────────────────────────────────────────────────────────

          programs.biome = {
            enable = true;
            settings.formatter = {
              "indentStyle" = "space";
              "indentWidth" = cfg.indent-width;
              "lineWidth" = cfg.line-length;
            };
            settings.css.linter.enabled = false;
          };

          # ────────────────────────────────────────────────────────────────────────
          #                                                            // lua // lint
          # ────────────────────────────────────────────────────────────────────────

          programs.stylua = {
            enable = true;
            settings = {
              "column_width" = cfg.line-length;
              "indent_type" = "Spaces";
              "indent_width" = cfg.indent-width;
            };
          };

          # ────────────────────────────────────────────────────────────────────────
          #                                                        // haskell // lint
          # ────────────────────────────────────────────────────────────────────────

          # NOTE: fourmolu disabled until ghc-lib-parser supports GHC 9.12 syntax.
          # fourmolu 0.15.0 uses ghc-lib-parser 9.8 which doesn't parse postpositive
          # qualified imports (`import Data.Text qualified as T`), a GHC2024 default.
          # See: https://github.com/fourmolu/fourmolu/issues/438
          programs.fourmolu.enable = false;

          # NOTE: hlint disabled — it's a linter, not a formatter, and treefmt-nix
          # doesn't support the config file needed to suppress suggestions.
          # We use our own straylight-haskell-lint instead which enforces:
          #   - THE GUARD MANDATE (no nested case/if)
          #   - DerivingStrategies required
          #   - Proper naming conventions

          # ────────────────────────────────────────────────────────────────────────
          #                                                          // other // lint
          # ────────────────────────────────────────────────────────────────────────

          programs.taplo = {
            enable = true;
            # Exclude template files with @substitution@ placeholders
            excludes = [ "nix/modules/flake/nativelink/scripts/*-fly.toml" ];
          };
          programs.yamlfmt.enable = true;
          programs.mdformat = {
            enable = true;
            # Exclude RFC docs that have complex tables mdformat can't handle
            excludes = [ "docs/rfc/sense-008-continuity/*" ];
          };
          programs.just.enable = true;
          programs.keep-sorted.enable = true;

          # ────────────────────────────────────────────────────────────────────────
          #                                                 // custom // formatters
          # ────────────────────────────────────────────────────────────────────────

          settings.formatter = {
            # ── nix // sense-lint ────────────────────────────────────────────────

            sense-lint = {
              command = lib.getExe inputs.self.packages.${system}.sense-lint;
              includes = [ "*.nix" ];
              # Exclude:
              # - prelude/lib: FP primitives where rec/or-null are legitimate
              # - nixos modules: no access to Dhall prelude for templating
              # - packages/overlays: bootstrap code that doesn't have access to prelude
              # - flake.nix: root bootstrap file that defines the prelude
              # - devshell: shell hook generation has long inline scripts
              # - sensenet module: toolchain generation has long inline scripts
              # - nix-compile: has long inline scripts for type checking
              # - test: integration tests have long inline scripts
              excludes = [
                "nix/prelude/*"
                "nix/lib/*"
                "nix/modules/nixos/*"
                "nix/packages/*"
                "nix/overlays/*"
                "nix/modules/flake/devshell.nix"
                "nix/modules/flake/sensenet/*"
                "nix/modules/flake/nix-compile/*"
                "nix/modules/flake/buck2/*"
                "test/*"
                "flake.nix"
              ];
            };

            # ── cpp // clang-tidy ────────────────────────────────────────────────

            clang-tidy = lib.mkIf cfg.cpp.enable-clang-tidy {
              command = clang-tidy-wrapper;
              includes = cpp-includes;
            };

            # ── cpp // cppcheck ──────────────────────────────────────────────────

            cppcheck = lib.mkIf cfg.cpp.enable-cppcheck {
              command = cppcheck-wrapper;
              includes = cpp-includes;
            };

            # ── cpp // sense-grep ────────────────────────────────────────────────

            sense-grep-cpp = lib.mkIf cfg.cpp.enable-sense-grep {
              command = sense-grep-cpp-wrapper;
              includes = cpp-includes;
            };

            # ── haskell // straylight-lint ───────────────────────────────────────
            #
            # Enforces THE GUARD MANDATE:
            #   - No nested case expressions (max 2 per function)
            #   - No nested if-then-else
            #   - DerivingStrategies must be explicit
            #
            # See: HASKELL_STYLE_GUIDE.md
            #
            # ─────────────────────────────────────────────────────────────────────

            straylight-haskell-lint = lib.mkIf cfg.haskell.enable-style-lint {
              command = haskell-lint-wrapper;
              includes = [ "*.hs" ];
              excludes = [
                # vendored code
                "vendor/*"
                # test files may have intentional violations
                "test/*"
                # benchmarks prioritize performance measurement over style
                "bench/*"
                # generated code
                "dist-newstyle/*"
                "sensenet-out/*"
              ];
            };
          };

          "flakeCheck" = cfg.enable-check;
        };
      };
  };
}
