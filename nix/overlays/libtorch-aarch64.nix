# nix/overlays/libtorch-aarch64.nix
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                           // libtorch-aarch64 //
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# Provides libtorch for aarch64-linux by extracting from PyTorch wheel.
# Nixpkgs libtorch-bin only supports x86_64-linux and aarch64-darwin because
# PyTorch doesn't publish standalone libtorch archives for aarch64-linux,
# but the wheel contains the same libraries.
#
# Uses autoPatchelfHook to patch the libraries with correct RPATH so
# dependencies like OpenBLAS are found at runtime without LD_LIBRARY_PATH.
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
_final: prev:
let
  is-aarch64-linux = prev.stdenv.hostPlatform.system == "aarch64-linux";

  # PyTorch 2.9.0 wheel for aarch64-linux (CPU version, no CUDA)
  torch-wheel = prev.fetchurl {
    url = "https://files.pythonhosted.org/packages/d1/d3/3985739f3b8e88675127bf70f82b3a48ae083e39cda56305dbd90398fec0/torch-2.9.0-cp312-cp312-manylinux_2_28_aarch64.whl";
    hash = "sha256-5fevHcTAp8SiYMJTT0HdryCXFPfIkUXmRMRHEvvWtkI=";
  };

  # Extract libtorch from wheel and patch with autoPatchelfHook
  libtorch-from-wheel = prev.stdenv.mkDerivation {
    pname = "libtorch";
    version = "2.9.0";

    src = torch-wheel;

    nativeBuildInputs = [
      prev.unzip
      prev.autoPatchelfHook
    ];

    # Runtime dependencies - autoPatchelfHook will add these to RPATH
    # The wheel bundles its own OpenBLAS, gomp, and ARM Compute Library
    # in torch.libs/, so we only need basic system libraries.
    buildInputs = [
      prev.stdenv.cc.cc.lib # libstdc++, libgcc_s
      prev.zlib
    ];

    unpackPhase = ''
      unzip $src -d unpacked
    '';

    installPhase = ''
      mkdir -p $out/{lib,include,share}

      # Copy main torch libraries
      cp -r unpacked/torch/lib/* $out/lib/

      # Copy bundled dependencies (torch.libs/ contains OpenBLAS, gomp, ARM Compute, etc.)
      # These have unique hashes in their names and are required by libtorch_cpu.so
      if [ -d unpacked/torch.libs ]; then
        cp -r unpacked/torch.libs/* $out/lib/
      fi

      # Copy headers
      if [ -d unpacked/torch/include ]; then
        cp -r unpacked/torch/include/* $out/include/
      fi

      # Copy share (cmake configs, etc)
      if [ -d unpacked/torch/share ]; then
        cp -r unpacked/torch/share/* $out/share/
      fi
    '';

    # Don't strip - these are prebuilt binaries
    dontStrip = true;

    meta = {
      description = "PyTorch C++ API (libtorch) extracted from wheel";
      homepage = "https://pytorch.org/";
      license = prev.lib.licenses.bsd3;
      platforms = [ "aarch64-linux" ];
    };
  };
in
prev.lib.optionalAttrs is-aarch64-linux {
  # Override libtorch-bin to use our wheel-extracted version on aarch64-linux
  libtorch-bin = libtorch-from-wheel;

  # Also provide as libtorch for compatibility
  libtorch = libtorch-from-wheel;
}
