-- buckconfig-nv.dhall
-- Generate [nv] section for .buckconfig.local
--
-- Environment variables:
--   NVIDIA_SDK_PATH, NVIDIA_SDK_INCLUDE, NVIDIA_SDK_LIB
--   CLANG (unwrapped), PTXAS, FATBINARY
--   ARCHS (comma-separated), MDSPAN_INCLUDE

let nvidia_sdk_path = env:NVIDIA_SDK_PATH as Text
let nvidia_sdk_include = env:NVIDIA_SDK_INCLUDE as Text
let nvidia_sdk_lib = env:NVIDIA_SDK_LIB as Text
let clang = env:CLANG as Text
let ptxas = env:PTXAS as Text
let fatbinary = env:FATBINARY as Text
let archs = env:ARCHS as Text
let mdspan_include = env:MDSPAN_INCLUDE ? "" as Text

in ''
[nv]
# NVIDIA SDK from Nix (NOT a compiler - just headers and runtime)
nvidia_sdk_path = ${nvidia_sdk_path}
nvidia_sdk_include = ${nvidia_sdk_include}
nvidia_sdk_lib = ${nvidia_sdk_lib}

# Unwrapped clang for CUDA (no NixOS hardening flags)
clang = ${clang}

# nvidia-sdk tools for PTX assembly
ptxas = ${ptxas}
fatbinary = ${fatbinary}

# Target architectures (comma-separated)
archs = ${archs}
${if mdspan_include == "" then "" else "mdspan_include = ${mdspan_include}"}
''
