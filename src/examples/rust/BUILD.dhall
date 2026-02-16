--| Rust examples (new format)

let A = ../../../dhall/prelude/package.dhall

let hello = A.rustBinary "hello-rs" ["hello.rs"] ([] : List A.Dep)
let mathlib = A.rustLibrary "mathlib" ["mathlib.rs"] ([] : List A.Dep)
let math_demo = A.rustBinary "math_demo" ["math_demo.rs"] [A.local ":mathlib"]

in  { targets =
        [ A.rule.rustBinary hello
        , A.rule.rustLibrary mathlib
        , A.rule.rustBinary math_demo
        ]
    }
