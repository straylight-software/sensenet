let A = ../../../dhall/prelude/package.dhall

in  [ A.binary "twitter" ["twitter.cpp"] [A.nix "simdjson"]
        // { std = A.CxxStd.Cxx20, cflags = ["-O2"] }
    ]
