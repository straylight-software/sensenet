--| Aleph Prelude

let T = ./Types.dhall
let C = ./Cxx.dhall
let R = ./Rust.dhall

in  { -- Types
      Dep = T.Dep
    , CxxStd = T.CxxStd
    , RustEdition = R.Edition
    , Vis = T.Vis
    -- Dep constructors
    , local = T.local
    , flake = T.flake
    , nix = T.nix
    -- C++ rules
    , CxxBinary = C.Binary
    , cxxBinary = C.binary
    , CxxLibrary = C.Library
    , cxxLibrary = C.library
    -- Rust rules
    , RustBinary = R.Binary
    , rustBinary = R.binary
    , RustLibrary = R.Library
    , rustLibrary = R.library
    -- Backward compat (short names for common case)
    , Binary = C.Binary
    , binary = C.binary
    , Library = C.Library
    , library = C.library
    }
