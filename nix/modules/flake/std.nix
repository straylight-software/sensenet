# nix/modules/flake/std.nix
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                                                            // ℵ-0xFF // std
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# Core nixpkgs configuration with LLVM-git overlay.
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{ inputs }:
{ config, lib, ... }:
let
  cfg = config.aleph;
  llvm-git-overlay = import ../../overlays/llvm-git.nix { inherit inputs; };
in
{
  _class = "flake";

  options.aleph = {
    nixpkgs.allow-unfree = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Allow unfree packages";
    };

    overlays.extra = lib.mkOption {
      type = lib.types.listOf lib.types.raw;
      default = [ ];
      description = "Additional overlays to apply";
    };
  };

  config.perSystem =
    { system, ... }:
    let
      pkgs-configured = import inputs.nixpkgs {
        inherit system;
        config.allowUnfree = cfg.nixpkgs.allow-unfree;
        overlays = [ llvm-git-overlay ] ++ cfg.overlays.extra;
      };
    in
    {
      _module.args.pkgs = lib.mkForce pkgs-configured;
      legacyPackages = lib.mkForce pkgs-configured;
    };
}
