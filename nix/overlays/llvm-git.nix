# nix/overlays/llvm-git.nix
#
# LLVM 22 from straylight-software/llvm-project fork
#
# Provides llvm-git package with:
#   - SM120 (Blackwell) support
#   - NVPTX target for CUDA compilation
#   - Cached in weyl-ai.cachix.org
#
{ inputs }:
_final: prev:
let
  inherit (prev) lib stdenv;
  is-linux = stdenv.isLinux;
in
lib.optionalAttrs is-linux {
  # Use llvm-git from the llvm-project flake
  inherit (inputs.llvm-project.packages.${stdenv.hostPlatform.system}) llvm-git;
}
