--| Nix-integrated C++ rules
--|
--| These use nix_cxx_binary which resolves flake refs at build time

let T = ./Types.dhall

-- | C++ binary with Nix flake dependencies
let NixBinary =
      { name : Text
      , srcs : List Text
      , nix_deps : List Text       -- Flake refs like "nixpkgs#zlib"
      , deps : List Text           -- Regular Buck2 deps
      , compiler_flags : List Text
      , linker_flags : List Text
      , vis : T.Vis
      }

let nixBinary
    : Text -> List Text -> List Text -> NixBinary
    = \(name : Text) ->
      \(srcs : List Text) ->
      \(nix_deps : List Text) ->
        { name, srcs, nix_deps
        , deps = [] : List Text
        , compiler_flags = [] : List Text
        , linker_flags = [] : List Text
        , vis = T.Vis.Public
        }

in  { NixBinary, nixBinary }
