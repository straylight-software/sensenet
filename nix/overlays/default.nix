# nix/overlays/default.nix
#
# ℵ-0xFF overlays
#
inputs:
let
  llvm-git-overlay = import ./llvm-git.nix { inherit inputs; };
in
{
  flake.overlays = {
    llvm-git = llvm-git-overlay;
    default = llvm-git-overlay;
  };
}
