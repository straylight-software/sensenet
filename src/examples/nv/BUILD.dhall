--| NVIDIA examples using clang (NOT nvcc)
--|
--| NOTE: Requires nvidia-sdk in the toolchain.

let A = ../../../dhall/prelude/package.dhall
let S = ../../../dhall/prelude/to-starlark.dhall

let hello = A.nvBinary "hello" ["hello.cpp"]
let mdspan = A.nvBinary "mdspan_device_test" ["mdspan_device_test.cpp"]
let tensor_core = A.nvBinary "tensor_core" ["tensor_core.cpp"]

in  { rules =
        [ S.nvBinary hello
        , S.nvBinary mdspan
        , S.nvBinary tensor_core
        ]
    , header = ''
        load("@toolchains//:nv.bzl", "nv_binary")
        ''
    }
