-- nv-section.dhall
-- Generate [nv] section for buckconfig.local

let nvidia_sdk = env:NVIDIA_SDK as Text
let clang = env:CLANG as Text
let mdspan = env:MDSPAN as Text

in ''

[nv]
nvidia_sdk_path = ${nvidia_sdk}
nvidia_sdk_include = ${nvidia_sdk}/include
nvidia_sdk_lib = ${nvidia_sdk}/lib
ptxas = ${nvidia_sdk}/bin/ptxas
fatbinary = ${nvidia_sdk}/bin/fatbinary
archs = sm_90
# Use unwrapped clang for CUDA (avoids NixOS hardening flags like -fzero-call-used-regs)
clang = ${clang}
# mdspan for device code (Kokkos reference implementation)
mdspan_include = ${mdspan}/include
''
