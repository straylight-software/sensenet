--| Rust examples using hermetic Nix toolchain
--|
--| Demonstrates:
--|   - rustBinary: standalone executable
--|   - rustLibrary: reusable library crate
--|   - Dependency chaining between targets

let A = ../../../dhall/prelude/package.dhall
let S = ../../../dhall/prelude/to-starlark.dhall

let hello = A.rustBinary "hello-rs" ["hello.rs"] ([] : List A.Dep)

let mathlib = A.rustLibrary "mathlib" ["mathlib.rs"] ([] : List A.Dep)

let math_demo = A.rustBinary "math_demo" ["math_demo.rs"] [A.local ":mathlib"]

in  { rules =
        [ S.rustBinary hello
        , S.rustLibrary mathlib
        , S.rustBinary math_demo
        ]
    , header = ''
        load("@toolchains//:rust.bzl", "rust_binary", "rust_library")
        ''
    }
