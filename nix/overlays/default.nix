# nix/overlays/default.nix
#
# ℵ-0xFF overlays
#
inputs:
let
  llvm-git-overlay = import ./llvm-git.nix { inherit inputs; };
  haskell-overlay = import ./haskell.nix { inherit inputs; };
in
{
  flake.overlays = {
    llvm-git = llvm-git-overlay;
    haskell = haskell-overlay;
    default = llvm-git-overlay;
  };
}
