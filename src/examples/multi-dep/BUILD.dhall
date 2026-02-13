--| Multi-dependency example with zlib, openssl, and curl

let A = ../../../dhall/prelude/package.dhall
let S = ../../../dhall/prelude/to-starlark.dhall

let multiDep =
      (A.nixCxxBinary "multi-dep" ["main.cpp"] 
        ["nixpkgs#zlib", "nixpkgs#openssl", "nixpkgs#curl"])
        with compiler_flags = ["-O2", "-Wall"]

in  { rules = [ S.nixCxxBinary multiDep ]
    , header = ''
        load("@toolchains//:nix_analyze.bzl", "nix_cxx_binary")
        ''
    }
