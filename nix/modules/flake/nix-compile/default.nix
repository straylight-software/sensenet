# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                                          // sense/net // nix-compile // module
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
#     "Case had always taken it for granted that the real bosses, the
#      kingpins in a given industry, would be both more and less than
#      people... he'd seen it in the eyes of the men at the Sense/Net
#      boardroom: a rich emptiness, a palpable sense of unfinished things."
#
#                                                               — Neuromancer
#
# Integrates nix-compile static analysis with sensenet's build graph verification.
#
# This module bridges:
#   - nix-compile: Type inference for Nix/bash (Hindley-Milner + row polymorphism)
#   - sensenet: Typed build graphs (Dhall → Starlark) with proof obligations
#
# The integration provides:
#   1. Type-check all Nix in the build graph
#   2. Verify Dhall configurations are well-typed
#   3. Cross-language dependency tracking (Nix → Dhall → buck2)
#   4. Proof obligation validation via DischargeProof.dhall
#
# USAGE:
#
#   {
#     inputs.nix-compile.url = "github:straylight-software/nix-compile";
#     inputs.sensenet.url = "github:straylight-software/sensenet";
#
#     outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } {
#       imports = [
#         inputs.sensenet.flakeModules.default
#         inputs.sensenet.flakeModules.nix-compile
#       ];
#
#       sense.nix-compile = {
#         enable = true;
#         profile = "strict";
#         verify-proofs = true;
#       };
#     };
#   }
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{ inputs }:
{
  config,
  lib,
  ...
}:
let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    mkIf
    ;
  cfg = config.sense.nix-compile;
in
{
  _class = "flake";

  # ════════════════════════════════════════════════════════════════════════════
  # Options
  # ════════════════════════════════════════════════════════════════════════════

  options.sense.nix-compile = {
    enable = mkEnableOption "nix-compile integration with sensenet";

    profile = mkOption {
      type = types.enum [
        "strict"
        "standard"
        "minimal"
        "security"
      ];
      default = "strict";
      description = ''
        Analysis profile. sensenet defaults to strict because we're
        building verified infrastructure.
      '';
    };

    paths = mkOption {
      type = types.listOf types.str;
      default = [
        "nix"
        "dhall"
        "toolchains"
      ];
      description = "Paths to analyze.";
    };

    verify-dhall = mkOption {
      type = types.bool;
      default = true;
      description = "Type-check Dhall configurations.";
    };

    verify-proofs = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Verify proof obligations in DischargeProof.dhall are satisfiable.
        Requires Lean4 toolchain.
      '';
    };

    cross-language = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable cross-language dependency tracking.
        Traces data flow from Nix → Dhall → Starlark.
      '';
    };

    buck2-graph = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Analyze buck2 build graph for type consistency.
        Requires buck2 in path.
      '';
    };
  };

  # ════════════════════════════════════════════════════════════════════════════
  # Config
  # ════════════════════════════════════════════════════════════════════════════

  config = mkIf cfg.enable {
    perSystem =
      {
        pkgs,
        system,
        ...
      }:
      let
        # Get nix-compile from inputs or fail with helpful message
        nix-compile =
          inputs.nix-compile.packages.${system}.default or (throw ''
            sense.nix-compile requires nix-compile input.
            Add to your flake inputs:
              nix-compile.url = "github:straylight-software/nix-compile";
          '');

        # Dhall packages for type-checking
        inherit (pkgs) dhall;
        inherit (pkgs) dhall-json;

        # Path arguments
        path-args = lib.escapeShellArgs cfg.paths;

        # Import centralized render-dhall function
        render-dhall = import ../../lib/render-dhall.nix { inherit pkgs lib; };

        # Scripts directory for Dhall templates
        scripts-dir = ./scripts;

        # ── nix-compile check ───────────────────────────────────────────────
        check-nix-script = render-dhall "check-nix-script" (scripts-dir + "/check-nix.dhall") {
          inputs-self = inputs.self;
          inherit (cfg) profile;
          inherit path-args;
        };
        check-nix = pkgs.runCommand "sense-nix-compile" {
          nativeBuildInputs = [ nix-compile ];
        } (builtins.readFile check-nix-script);

        # ── dhall type check ────────────────────────────────────────────────
        check-dhall-script = render-dhall "check-dhall-script" (scripts-dir + "/check-dhall.dhall") {
          inputs-self = inputs.self;
        };
        check-dhall = pkgs.runCommand "sense-dhall-typecheck" {
          nativeBuildInputs = [
            dhall
            dhall-json
          ];
        } (builtins.readFile check-dhall-script);

        # ── cross-language check ────────────────────────────────────────────
        check-cross-lang-script =
          render-dhall "check-cross-lang-script" (scripts-dir + "/check-cross-lang.dhall")
            {
              inputs-self = inputs.self;
            };
        check-cross-lang = pkgs.runCommand "sense-cross-language" {
          nativeBuildInputs = [
            nix-compile
            dhall
            dhall-json
          ];
        } (builtins.readFile check-cross-lang-script);

        # ── buck2 graph check ───────────────────────────────────────────────
        check-buck2-graph-script =
          render-dhall "check-buck2-graph-script" (scripts-dir + "/check-buck2-graph.dhall")
            {
              inputs-self = inputs.self;
            };
        check-buck2-graph = pkgs.runCommand "sense-buck2-graph" {
          nativeBuildInputs = [
            pkgs.buck2
            dhall
            dhall-json
          ];
        } (builtins.readFile check-buck2-graph-script);

        # ── proof verification ──────────────────────────────────────────────
        check-proofs-script = render-dhall "check-proofs-script" (scripts-dir + "/check-proofs.dhall") {
          inputs-self = inputs.self;
        };
        check-proofs = pkgs.runCommand "sense-proof-verify" {
          nativeBuildInputs = [
            pkgs.lean4
            dhall
            dhall-json
          ];
        } (builtins.readFile check-proofs-script);

        # ── combined check ──────────────────────────────────────────────────
        all-checks-script = render-dhall "all-checks-script" (scripts-dir + "/all-checks.dhall") {
          inherit check-nix;
          inherit check-dhall;
          inherit check-cross-lang;
          inherit check-buck2-graph;
          inherit check-proofs;
          inherit (cfg) verify-dhall;
          inherit (cfg) cross-language;
          inherit (cfg) buck2-graph;
          inherit (cfg) verify-proofs;
        };
        all-checks = pkgs.runCommand "sense-all-checks" {
          nativeBuildInputs = [ ];
        } (builtins.readFile all-checks-script);

      in
      {
        # Export individual checks
        checks = {
          sense-nix-compile = check-nix;
        }
        // lib.optionalAttrs cfg.verify-dhall {
          sense-dhall = check-dhall;
        }
        // lib.optionalAttrs cfg.cross-language {
          sense-cross-lang = check-cross-lang;
        }
        // lib.optionalAttrs cfg.buck2-graph {
          sense-buck2-graph = check-buck2-graph;
        }
        // lib.optionalAttrs cfg.verify-proofs {
          sense-proofs = check-proofs;
        };

        # Combined package
        packages.sense-verify = all-checks;
      };
  };
}
