--| Source.dhall - Source Specifications
--|
--| Where code comes from: local files, HTTP fetch, Git, crates.io
--| Everything content-addressed for reproducibility.
--|
--| straylight.software · 2026

let Toolchain = ./Toolchain.dhall

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- SOURCE TYPES
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let Src =
      < Files : List Text                      -- Local files
      | Fetch : { url : Text, sha256 : Text }  -- HTTP fetch (CA)
      | Git : { url : Text, rev : Text, sha256 : Text }  -- Git (CA)
      >

let files
    : List Text -> Src
    = \(fs : List Text) -> Src.Files fs

let fetch
    : Text -> Text -> Src
    = \(url : Text) ->
      \(sha256 : Text) ->
        Src.Fetch { url, sha256 }

let git
    : Text -> Text -> Text -> Src
    = \(url : Text) ->
      \(rev : Text) ->
      \(sha256 : Text) ->
        Src.Git { url, rev, sha256 }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- CRATES.IO
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let CratesIo =
      { name : Text
      , version : Text
      , sha256 : Text
      , features : List Text
      , deps : List Text
      , proc_macro : Bool
      }

let cratesIo
    : Text -> Text -> Text -> CratesIo
    = \(name : Text) ->
      \(version : Text) ->
      \(sha256 : Text) ->
        { name
        , version
        , sha256
        , features = [] : List Text
        , deps = [] : List Text
        , proc_macro = False
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- HTTP ARCHIVE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let HttpArchive =
      { name : Text
      , url : Text
      , sha256 : Text
      , strip_prefix : Optional Text
      }

let httpArchive
    : Text -> Text -> Text -> HttpArchive
    = \(name : Text) ->
      \(url : Text) ->
      \(sha256 : Text) ->
        { name
        , url
        , sha256
        , strip_prefix = None Text
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- NPM PACKAGE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let NpmPackage =
      { name : Text
      , version : Text
      , sha256 : Text
      , dev : Bool
      }

let npmPackage
    : Text -> Text -> Text -> NpmPackage
    = \(name : Text) ->
      \(version : Text) ->
      \(sha256 : Text) ->
        { name
        , version
        , sha256
        , dev = False
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- PYPI PACKAGE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let PyPIPackage =
      { name : Text
      , version : Text
      , sha256 : Text
      , extras : List Text
      }

let pypiPackage
    : Text -> Text -> Text -> PyPIPackage
    = \(name : Text) ->
      \(version : Text) ->
      \(sha256 : Text) ->
        { name
        , version
        , sha256
        , extras = [] : List Text
        }

in  { -- Source types
      Src
    , files
    , fetch
    , git
    -- Crates.io
    , CratesIo
    , cratesIo
    -- HTTP archive
    , HttpArchive
    , httpArchive
    -- NPM
    , NpmPackage
    , npmPackage
    -- PyPI
    , PyPIPackage
    , pypiPackage
    }
