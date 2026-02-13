# nix/overlays/default.nix
#
# ℵ-0xFF overlays
#
inputs:
let
  inherit (inputs.nixpkgs) lib;
  llvm-git-overlay = import ./llvm-git.nix { inherit inputs; };
  nvidia-sdk-overlay = import ./nvidia-sdk.nix { inherit inputs; };
  haskell-overlay = import ./haskell.nix { inherit inputs; };
in
{
  flake.overlays = {
    llvm-git = llvm-git-overlay;
    nvidia-sdk = nvidia-sdk-overlay;
    haskell = haskell-overlay;
    default = lib.composeManyExtensions [
      llvm-git-overlay
      nvidia-sdk-overlay
    ];
  };
}
