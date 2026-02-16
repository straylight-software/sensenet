-- nv-config.dhall
-- NV config section for devshell

let nvidia_sdk = env:NVIDIA_SDK as Text
let clang_unwrapped = env:CLANG_UNWRAPPED as Text
let mdspan = env:MDSPAN as Text

in ''
[nv]
nvidia_sdk_path = ${nvidia_sdk}
nvidia_sdk_include = ${nvidia_sdk}/include
nvidia_sdk_lib = ${nvidia_sdk}/lib
clang = ${clang_unwrapped}/bin/clang++
ptxas = ${nvidia_sdk}/bin/ptxas
fatbinary = ${nvidia_sdk}/bin/fatbinary
mdspan_include = ${mdspan}/include
''
