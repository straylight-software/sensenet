--| SQLite3 example with Nix-resolved dependencies

let A = ../../../dhall/prelude/package.dhall
let S = ../../../dhall/prelude/to-starlark.dhall

let sqliteTest =
      (A.nixCxxBinary "sqlite-test" ["main.cpp"] ["nixpkgs#sqlite"])
        with compiler_flags = ["-O2", "-Wall"]

in  { rules = [ S.nixCxxBinary sqliteTest ]
    , header = ''
        load("@toolchains//:nix_analyze.bzl", "nix_cxx_binary")
        ''
    }
