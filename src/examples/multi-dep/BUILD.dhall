let A = ../../../dhall/prelude/package.dhall

in  [ A.binary "multi-dep" ["main.cpp"]
        [A.nix "zlib", A.nix "openssl", A.nix "curl"]
        // { cflags = ["-O2", "-Wall"] }
    ]
