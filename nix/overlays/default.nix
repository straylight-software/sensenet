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
  # PureScript overlay from thomashoneyman - provides purs, spago-unstable
  purescript-overlay = inputs.purescript-overlay.overlays.default;
in
{
  flake.overlays = {
    llvm-git = llvm-git-overlay;
    nvidia-sdk = nvidia-sdk-overlay;
    haskell = haskell-overlay;
    purescript = purescript-overlay;
    default = lib.composeManyExtensions [
      llvm-git-overlay
      nvidia-sdk-overlay
      purescript-overlay
    ];
  };
}
