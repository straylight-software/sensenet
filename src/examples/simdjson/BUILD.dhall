--| simdjson example with Nix-resolved dependencies

let A = ../../../dhall/prelude/package.dhall
let S = ../../../dhall/prelude/to-starlark.dhall

let twitter =
      (A.nixCxxBinary "twitter" ["twitter.cpp"] ["nixpkgs#simdjson"])
        with compiler_flags = ["-O2"]

in  { rules = [ S.nixCxxBinary twitter ]
    , header = ''
        load("@toolchains//:nix_analyze.bzl", "nix_cxx_binary")
        ''
    }
