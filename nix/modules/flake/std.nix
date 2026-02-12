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
  cfg = config.sense;
  llvm-git-overlay = import ../../overlays/llvm-git.nix { inherit inputs; };
  nvidia-sdk-overlay = import ../../overlays/nvidia-sdk.nix { inherit inputs; };
  libtorch-aarch64-overlay = import ../../overlays/libtorch-aarch64.nix;

  haskell-overlay = import ../../overlays/haskell.nix { inherit inputs; };
in
{
  _class = "flake";

  options.sense = {
    nixpkgs.allow-unfree = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Allow unfree packages";
    };

    llvm-git.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable LLVM 22 from git overlay.
        Required for SM120 Blackwell support and clean CUDA compilation.
        Disabled by default as it requires building from source (~30min).
      '';
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
      llvm-overlays = lib.optionals cfg.llvm-git.enable [ llvm-git-overlay ];
      pkgs-configured = import inputs.nixpkgs {
        inherit system;
        config.allowUnfree = cfg.nixpkgs.allow-unfree;
        overlays =
          llvm-overlays
          ++ [
            nvidia-sdk-overlay
            libtorch-aarch64-overlay

            haskell-overlay
          ]
          ++ cfg.overlays.extra;
      };
    in
    {
      _module.args.pkgs = lib.mkForce pkgs-configured;
      legacyPackages = lib.mkForce { };
    };


}
