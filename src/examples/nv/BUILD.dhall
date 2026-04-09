--| NVIDIA CUDA examples

let E = ../../../dhall/evring/Compat.dhall

let hello = E.nv_binary "hello" ["hello.cpp"]
let mdspan = E.nv_binary "mdspan_device_test" ["mdspan_device_test.cpp"]
let tensor_core = E.nv_binary "tensor_core" ["tensor_core.cpp"]

in  { targets =
        [ E.rule.nvBinary hello
        , E.rule.nvBinary mdspan
        , E.rule.nvBinary tensor_core
        ]
    }
