--| Aleph Prelude

let T = ./Types.dhall
let C = ./Cxx.dhall

in  { Dep = T.Dep
    , CxxStd = T.CxxStd
    , Vis = T.Vis
    , local = T.local
    , flake = T.flake
    , nix = T.nix
    , Binary = C.Binary
    , binary = C.binary
    , Library = C.Library
    , library = C.library
    }
