{- BUILD-nix.dhall

   Example using nix_genrule approach.
   
   This target depends on nixpkgs#zlib, which gets resolved at build time
   inside the genrule (not at Buck2 analysis time).
-}

let Build = ../../../dhall/Build.dhall
let Toolchain = ../../../dhall/Toolchain.dhall
let Resource = ../../../dhall/Resource.dhall

in  Build.cxx-binary
      { name = "zlib-test"
      , srcs = [ "main.cpp" ]
      , deps = [ Build.dep.nixpkgs "zlib" ]  -- Dep.Flake "nixpkgs#zlib"
      , toolchain = Toolchain.presets.clang-18-glibc-dynamic
      , requires = Resource.pure  -- Pure build: no network access needed at build time
      }
