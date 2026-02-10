--| src/examples/simdjson/BUILD.dhall
--|
--| simdjson demo - SIMD-accelerated JSON parsing at 4+ GB/s
--|
--| This is the source of truth. Run:
--|   dhall-to-buck ./BUILD.dhall > BUCK

let A = ../../../dhall/prelude/package.dhall

in  [ A.cxx_binary
        "twitter"
        [ "twitter.cpp" ]
        [ A.nixpkgs "simdjson" ]
      // { cxx_std = A.CxxStandard.Cxx20
         , compiler_flags = [ "-O2" ]
         }
    ]
