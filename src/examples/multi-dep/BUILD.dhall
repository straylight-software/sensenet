--| src/examples/multi-dep/BUILD.dhall
--|
--| Multiple Nix dependencies test
--| Uses: zlib, openssl, curl (curl depends on both)

let A = ../../../dhall/prelude/package.dhall

in  [ A.cxx_binary
        "multi-dep"
        [ "main.cpp" ]
        [ A.nixpkgs "zlib"
        , A.nixpkgs "openssl"
        , A.nixpkgs "curl"
        ]
      // { compiler_flags = [ "-O2", "-Wall" ] }
    ]
