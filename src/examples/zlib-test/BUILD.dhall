--| zlib test with Nix-resolved dependencies

let A = ../../../dhall/prelude/package.dhall
let S = ../../../dhall/prelude/to-starlark.dhall

let zlibTest =
      (A.nixCxxBinary "zlib-test" ["main.cpp"] ["nixpkgs#zlib"])
        with compiler_flags = ["-O2", "-Wall"]

in  { rules = [ S.nixCxxBinary zlibTest ]
    , header = ''
        load("@toolchains//:nix_analyze.bzl", "nix_cxx_binary")
        ''
    }
