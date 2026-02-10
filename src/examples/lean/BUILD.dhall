--| Lean 4 examples using hermetic Nix toolchain

let A = ../../../dhall/prelude/package.dhall
let S = ../../../dhall/prelude/to-starlark.dhall

let hello = A.leanBinary "hello-lean" ["Hello.lean"]
let hashmap = A.leanBinary "hashmap" ["HashMap.lean"]

in  { rules = [ S.leanBinary hello, S.leanBinary hashmap ]
    , header = ''
        load("@toolchains//:lean.bzl", "lean_binary")
        ''
    }
