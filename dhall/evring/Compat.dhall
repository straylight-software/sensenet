--| Compat.dhall - Compatibility layer for sensenet's Haskell parser
--|
--| This module provides evring-style constructors that output records
--| in the OLD format expected by sensenet's Dhall.hs parser.
--|
--| This allows BUILD.dhall files to use evring syntax while still
--| working with the existing Haskell parsing infrastructure.
--|
--| straylight.software · 2026

let T = ../prelude/Types.dhall
let Rules = ./Rules.dhall

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- C++ RULES (output old format)
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let OldCxxBinary =
      { name : Text
      , srcs : List Text
      , deps : List T.Dep
      , std : T.CxxStd
      , cflags : List Text
      , ldflags : List Text
      , vis : T.Vis
      }

let cxx_binary
    : Text -> List Text -> OldCxxBinary
    = \(name : Text) ->
      \(srcs : List Text) ->
        { name
        , srcs
        , deps = [] : List T.Dep
        , std = T.CxxStd.Cxx23
        , cflags = [] : List Text
        , ldflags = [] : List Text
        , vis = T.Vis.Public
        }

let OldCxxLibrary =
      { name : Text
      , srcs : List Text
      , hdrs : List Text
      , deps : List T.Dep
      , std : T.CxxStd
      , cflags : List Text
      , vis : T.Vis
      }

let cxx_library
    : Text -> List Text -> List Text -> OldCxxLibrary
    = \(name : Text) ->
      \(srcs : List Text) ->
      \(hdrs : List Text) ->
        { name
        , srcs
        , hdrs
        , deps = [] : List T.Dep
        , std = T.CxxStd.Cxx23
        , cflags = [] : List Text
        , vis = T.Vis.Public
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- RUST RULES (output old format)
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Old format uses E2015/E2018/E2021/E2024 instead of Edition*
let OldRustEdition = < E2015 | E2018 | E2021 | E2024 >

let OldRustBinary =
      { name : Text
      , srcs : List Text
      , deps : List T.Dep
      , edition : OldRustEdition
      , features : List Text
      , rustflags : List Text
      , vis : T.Vis
      }

let rust_binary
    : Text -> List Text -> OldRustBinary
    = \(name : Text) ->
      \(srcs : List Text) ->
        { name
        , srcs
        , deps = [] : List T.Dep
        , edition = OldRustEdition.E2024
        , features = [] : List Text
        , rustflags = [] : List Text
        , vis = T.Vis.Public
        }

let OldRustLibrary =
      { name : Text
      , srcs : List Text
      , deps : List T.Dep
      , edition : OldRustEdition
      , crate_name : Optional Text
      , features : List Text
      , proc_macro : Bool
      , vis : T.Vis
      }

let rust_library
    : Text -> List Text -> OldRustLibrary
    = \(name : Text) ->
      \(srcs : List Text) ->
        { name
        , srcs
        , deps = [] : List T.Dep
        , edition = OldRustEdition.E2024
        , crate_name = None Text
        , features = [] : List Text
        , proc_macro = False
        , vis = T.Vis.Public
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- HASKELL RULES (output old format)
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let OldHaskellBinary =
      { name : Text
      , srcs : List Text
      , main : Text
      , packages : List Text
      , language_extensions : List Text
      , ghc_options : List Text
      , deps : List T.Dep
      , extra_libs : List Text
      , extra_lib_dirs : List Text
      , vis : T.Vis
      }

let haskell_binary
    : Text -> List Text -> OldHaskellBinary
    = \(name : Text) ->
      \(srcs : List Text) ->
        { name
        , srcs
        , main = "Main"
        , packages = [ "base" ] : List Text
        , language_extensions = [] : List Text
        , ghc_options = [ "-O2", "-Wall" ] : List Text
        , deps = [] : List T.Dep
        , extra_libs = [] : List Text
        , extra_lib_dirs = [] : List Text
        , vis = T.Vis.Public
        }

let OldHaskellLibrary =
      { name : Text
      , srcs : List Text
      , packages : List Text
      , language_extensions : List Text
      , ghc_options : List Text
      , deps : List T.Dep
      , vis : T.Vis
      }

let haskell_library
    : Text -> List Text -> OldHaskellLibrary
    = \(name : Text) ->
      \(srcs : List Text) ->
        { name
        , srcs
        , packages = [ "base" ] : List Text
        , language_extensions = [] : List Text
        , ghc_options = [ "-O2", "-Wall" ] : List Text
        , deps = [] : List T.Dep
        , vis = T.Vis.Public
        }

let OldHaskellFFIBinary =
      { name : Text
      , hs_srcs : List Text
      , cxx_srcs : List Text
      , cxx_headers : List Text
      , packages : List Text
      , deps : List T.Dep
      , language_extensions : List Text
      , ghc_options : List Text
      , extra_libs : List Text
      , extra_lib_dirs : List Text
      , include_dirs : List Text
      , linker_flags : List Text
      , vis : T.Vis
      }

let haskell_ffi_binary
    : Text -> List Text -> List Text -> OldHaskellFFIBinary
    = \(name : Text) ->
      \(hs_srcs : List Text) ->
      \(cxx_srcs : List Text) ->
        { name
        , hs_srcs
        , cxx_srcs
        , cxx_headers = [] : List Text
        , packages = [ "base" ] : List Text
        , deps = [] : List T.Dep
        , language_extensions = [] : List Text
        , ghc_options = [ "-O2" ] : List Text
        , extra_libs = [] : List Text
        , extra_lib_dirs = [] : List Text
        , include_dirs = [] : List Text
        , linker_flags = [] : List Text
        , vis = T.Vis.Public
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- LEAN RULES (output old format)
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let OldLeanBinary =
      { name : Text
      , srcs : List Text
      , deps : List T.Dep
      , root_module : Optional Text
      , vis : T.Vis
      }

let lean_binary
    : Text -> List Text -> OldLeanBinary
    = \(name : Text) ->
      \(srcs : List Text) ->
        { name
        , srcs
        , deps = [] : List T.Dep
        , root_module = None Text
        , vis = T.Vis.Public
        }

let OldLeanLibrary =
      { name : Text
      , srcs : List Text
      , deps : List T.Dep
      , vis : T.Vis
      }

let lean_library
    : Text -> List Text -> OldLeanLibrary
    = \(name : Text) ->
      \(srcs : List Text) ->
        { name
        , srcs
        , deps = [] : List T.Dep
        , vis = T.Vis.Public
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- NVIDIA RULES (output old format)
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let OldNvBinary =
      { name : Text
      , srcs : List Text
      , deps : List T.Dep
      , archs : List Text
      , vis : T.Vis
      }

let nv_binary
    : Text -> List Text -> OldNvBinary
    = \(name : Text) ->
      \(srcs : List Text) ->
        { name
        , srcs
        , deps = [] : List T.Dep
        , archs = [] : List Text  -- uses default from toolchain
        , vis = T.Vis.Public
        }

let OldNvLibrary =
      { name : Text
      , srcs : List Text
      , exported_headers : List Text
      , deps : List T.Dep
      , archs : List Text
      , vis : T.Vis
      }

let nv_library
    : Text -> List Text -> OldNvLibrary
    = \(name : Text) ->
      \(srcs : List Text) ->
        { name
        , srcs
        , exported_headers = [] : List Text
        , deps = [] : List T.Dep
        , archs = [] : List Text
        , vis = T.Vis.Public
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- GENRULE (output old format)
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let OldGenrule =
      { name : Text
      , srcs : List Text
      , out : Text
      , cmd : Text
      , vis : T.Vis
      }

let genrule
    : Text -> Text -> Text -> OldGenrule
    = \(name : Text) ->
      \(out : Text) ->
      \(cmd : Text) ->
        { name
        , srcs = [] : List Text
        , out
        , cmd
        , vis = T.Vis.Public
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- NIX C++ RULES (output old format)
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let OldNixCxxBinary =
      { name : Text
      , srcs : List Text
      , nix_deps : List Text
      , deps : List Text
      , compiler_flags : List Text
      , linker_flags : List Text
      , vis : T.Vis
      }

let nix_cxx_binary
    : Text -> List Text -> List Text -> OldNixCxxBinary
    = \(name : Text) ->
      \(srcs : List Text) ->
      \(nix_deps : List Text) ->
        { name
        , srcs
        , nix_deps
        , deps = [] : List Text
        , compiler_flags = [] : List Text
        , linker_flags = [] : List Text
        , vis = T.Vis.Public
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- PURESCRIPT RULES (output old format)
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let SrcSpec = < Explicit : List Text | Glob : Text | Globs : List Text >

let OldPureScriptApp =
      { name : Text
      , srcs : SrcSpec
      , deps : List Text
      , package_set : Text
      , main : Text
      , index_html : Optional Text
      , style_css : Optional Text
      , vis : T.Vis
      }

let purescript_app
    : Text -> SrcSpec -> List Text -> OldPureScriptApp
    = \(name : Text) ->
      \(srcs : SrcSpec) ->
      \(deps : List Text) ->
        { name
        , srcs
        , deps
        , package_set = "psc-0.15.15-20240416"
        , main = "Main"
        , index_html = None Text
        , style_css = None Text
        , vis = T.Vis.Public
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- RUST CRATES.IO (output old format)
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let OldCratesIo =
      { name : Text
      , version : Text
      , sha256 : Text
      , features : List Text
      , deps : List Text
      , proc_macro : Bool
      , vis : T.Vis
      }

let crates_io
    : Text -> Text -> Text -> OldCratesIo
    = \(name : Text) ->
      \(version : Text) ->
      \(sha256 : Text) ->
        { name
        , version
        , sha256
        , features = [] : List Text
        , deps = [] : List Text
        , proc_macro = False
        , vis = T.Vis.Public
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- EXPORTS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

in  { -- Types (re-export from prelude for deps)
      Dep = T.Dep
    , local = T.local
    , flake = T.flake
    , nixpkgs = T.nix
    , SrcSpec
    
    -- C++
    , CxxBinary = OldCxxBinary
    , cxx_binary
    , CxxLibrary = OldCxxLibrary
    , cxx_library
    
    -- Rust
    , RustEdition = OldRustEdition
    , RustBinary = OldRustBinary
    , rust_binary
    , RustLibrary = OldRustLibrary
    , rust_library
    
    -- Rust crates.io
    , CratesIo = OldCratesIo
    , crates_io
    
    -- Haskell
    , HaskellBinary = OldHaskellBinary
    , haskell_binary
    , HaskellLibrary = OldHaskellLibrary
    , haskell_library
    , HaskellFFIBinary = OldHaskellFFIBinary
    , haskell_ffi_binary
    
    -- Lean
    , LeanBinary = OldLeanBinary
    , lean_binary
    , LeanLibrary = OldLeanLibrary
    , lean_library
    
    -- NVIDIA
    , NvBinary = OldNvBinary
    , nv_binary
    , NvLibrary = OldNvLibrary
    , nv_library
    
    -- Genrule
    , Genrule = OldGenrule
    , genrule
    
    -- Nix C++
    , NixCxxBinary = OldNixCxxBinary
    , nix_cxx_binary
    
    -- PureScript
    , PureScriptApp = OldPureScriptApp
    , purescript_app
    
    -- Rule constructors (wrap to Rule union)
    , rule =
        let Rule = ../prelude/Rule.dhall
        in  { cxxBinary = Rule.cxxBinary
            , cxxLibrary = Rule.cxxLibrary
            , rustBinary = Rule.rustBinary
            , rustLibrary = Rule.rustLibrary
            , haskellBinary = Rule.haskellBinary
            , haskellLibrary = Rule.haskellLibrary
            , haskellFFIBinary = Rule.haskellFFIBinary
            , leanBinary = Rule.leanBinary
            , leanLibrary = Rule.leanLibrary
            , nvBinary = Rule.nvBinary
            , nvLibrary = Rule.nvLibrary
            , genrule = Rule.genrule
            , nixCxxBinary = Rule.nixCxxBinary
            , purescriptApp = Rule.purescriptApp
            , cratesIo = Rule.cratesIo
            }
    }
