--| NVIDIA examples (new format)

let A = ../../../dhall/prelude/package.dhall

let hello = A.nvBinary "hello" ["hello.cpp"]
let mdspan = A.nvBinary "mdspan_device_test" ["mdspan_device_test.cpp"]
let tensor_core = A.nvBinary "tensor_core" ["tensor_core.cpp"]

in  { targets =
        [ A.rule.nvBinary hello
        , A.rule.nvBinary mdspan
        , A.rule.nvBinary tensor_core
        ]
    }
