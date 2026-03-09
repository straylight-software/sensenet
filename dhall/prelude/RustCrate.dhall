--| Rust crate fetching from crates.io

let T = ./Types.dhall

-- | Crate from crates.io
let CratesIo =
      { name : Text
      , version : Text
      , sha256 : Text
      , features : List Text
      , deps : List Text
      , proc_macro : Bool
      , vis : T.Vis
      }

let cratesIo
    : Text -> Text -> Text -> CratesIo
    = \(name : Text) ->
      \(version : Text) ->
      \(sha256 : Text) ->
        { name, version, sha256
        , features = [] : List Text
        , deps = [] : List Text
        , proc_macro = False
        , vis = T.Vis.Public
        }

-- | HTTP archive (generic tarball fetch)
let HttpArchive =
      { name : Text
      , url : Text
      , sha256 : Text
      , strip_prefix : Optional Text
      , vis : T.Vis
      }

let httpArchive
    : Text -> Text -> Text -> HttpArchive
    = \(name : Text) ->
      \(url : Text) ->
      \(sha256 : Text) ->
        { name, url, sha256
        , strip_prefix = None Text
        , vis = T.Vis.Public
        }

in  { CratesIo, cratesIo, HttpArchive, httpArchive }
