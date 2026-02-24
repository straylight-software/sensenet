--| Rust examples

let E = ../../../dhall/evring/Compat.dhall

let hello = E.rust_binary "hello-rs" ["hello.rs"]
let mathlib = E.rust_library "mathlib" ["mathlib.rs"]
let math_demo = (E.rust_binary "math_demo" ["math_demo.rs"]) with deps = [E.local ":mathlib"]

in  { targets =
        [ E.rule.rustBinary hello
        , E.rule.rustLibrary mathlib
        , E.rule.rustBinary math_demo
        ]
    }
