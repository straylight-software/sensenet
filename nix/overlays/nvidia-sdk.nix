# nix/overlays/nvidia-sdk.nix
#
# Provides nvidia-sdk from the weyl-ai/nvidia-sdk flake.
# This makes `pkgs.nvidia-sdk` available for other overlays (like haskell.nix).
#
{ inputs }:
final: _prev: {
  inherit (inputs.nvidia-sdk.packages.${final.stdenv.hostPlatform.system}) nvidia-sdk;
}
