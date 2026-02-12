# nix/overlays/llvm-git.nix
#
# LLVM 22 from git with SM120 Blackwell support
#
# Why build from source?
#   - nixpkgs clang's __clang_cuda_runtime_wrapper.h redefines uint3/dim3
#     as macros to __cuda_builtin_*_t types, breaking CCCL headers
#   - SM120 (Blackwell) support requires bleeding edge LLVM
#
{ inputs }:
_final: prev:
let
  inherit (prev) lib stdenv;
  is-linux = stdenv.isLinux;
in
lib.optionalAttrs is-linux {
  llvm-git = stdenv.mkDerivation {
    pname = "llvm-git";
    version = "22.0.0-git";

    src = inputs.llvm-project;

    sourceRoot = "source/llvm";

    nativeBuildInputs = [

      prev.cmake
      prev.ninja
      prev.python3
    ];

    buildInputs = [
      prev.libxml2
      prev.zlib
      prev.ncurses
      prev.libffi
    ];

    cmakeFlags = [
      "-DLLVM_ENABLE_PROJECTS=clang;clang-tools-extra;lld"
      "-DCMAKE_BUILD_TYPE=Release"
      "-DLLVM_TARGETS_TO_BUILD=X86;NVPTX;AArch64"
      "-DLLVM_ENABLE_ASSERTIONS=OFF"
      "-DLLVM_INSTALL_UTILS=ON"
      "-DLLVM_BUILD_TOOLS=ON"
      "-DLLVM_INCLUDE_TESTS=OFF"
      "-DLLVM_INCLUDE_EXAMPLES=OFF"
      "-DLLVM_INCLUDE_DOCS=OFF"
    ];

    enableParallelBuilding = true;

    meta = {
      description = "LLVM/Clang from git with CUDA 13 and SM120 Blackwell support";
      homepage = "https://llvm.org";
      license = lib.licenses.ncsa;
      platforms = lib.platforms.linux;
    };
  };
}
