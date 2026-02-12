# test/sensenet/toolchain-types.nix
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                                                  // test // toolchain-types //
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# FAILING TEST: nix-compile should infer types for sensenet toolchain definitions
#
# Expected: nix-compile infers the following types:
#
#   toolchain-paths : {
#     clang : Path,
#     ghc : Path,
#     lean : Path,
#     rustc : Path,
#     nvcc : Path,
#   }
#
#   mk-toolchain : ToolchainConfig → Toolchain
#
# Currently fails because:
#   1. nix-compile doesn't trace through inputs.* paths
#   2. Row polymorphism doesn't handle optional toolchain fields
#   3. Cross-file inference not implemented
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{
  lib,
  pkgs,
  inputs,
}:
let
  # Toolchain path configuration
  # :: { clang : Path, ghc : Path, lean : Path, rustc : Path, nvcc : Path }
  toolchain-paths = {
    clang = "${pkgs.llvmPackages_18.clang}/bin/clang";
    ghc = "${pkgs.haskell.compiler.ghc912}/bin/ghc";
    lean = "${pkgs.lean4}/bin/lean";
    rustc = "${pkgs.rustc}/bin/rustc";
    nvcc = "${pkgs.cudaPackages.cuda_nvcc}/bin/nvcc";
  };

  # Toolchain builder
  # :: ToolchainConfig → Toolchain
  mk-toolchain =
    {
      cxx ? { enable = false; },
      haskell ? { enable = false; },
      lean ? { enable = false; },
      rust ? { enable = false; },
      nv ? { enable = false; },
    }:
    {
      inherit cxx haskell lean rust nv;
      paths = toolchain-paths;
      # :: Derivation
      shell = pkgs.mkShell {
        packages =
          [ ]
          ++ lib.optionals cxx.enable [ pkgs.llvmPackages_18.clang ]
          ++ lib.optionals haskell.enable [ pkgs.haskell.compiler.ghc912 ]
          ++ lib.optionals lean.enable [ pkgs.lean4 ]
          ++ lib.optionals rust.enable [ pkgs.rustc pkgs.cargo ]
          ++ lib.optionals nv.enable [ pkgs.cudaPackages.cuda_nvcc ];
      };
    };

  # Example usage that should type-check
  # :: Toolchain
  example-toolchain = mk-toolchain {
    cxx.enable = true;
    haskell = {
      enable = true;
      packages = hp: [ hp.aeson hp.text ];
    };
    nv.enable = true;
  };
in
{
  inherit toolchain-paths mk-toolchain example-toolchain;
}
