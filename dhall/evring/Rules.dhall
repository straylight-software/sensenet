--| Rules.dhall - Build Rule Types
--|
--| rust_library, rust_binary, lean_library, cxx_binary, etc.
--| NO GLOBS. Explicit file lists only.
--|
--| Merges sensenet/prelude with armitage/Rules.dhall
--|
--| straylight.software · 2026

let Triple = ./Triple.dhall
let Toolchain = ./Toolchain.dhall
let Coeffect = ./Coeffect.dhall

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- VISIBILITY
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let Visibility =
      < Public
      | Private
      | Package
      | Targets : List Text
      >

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- DEPENDENCIES
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let Dep =
      < Local : Text                        -- :target or //pkg:target
      | Flake : { flake : Text, attr : Text } -- nixpkgs#zlib
      >

let local
    : Text -> Dep
    = \(target : Text) -> Dep.Local target

let flake
    : Text -> Text -> Dep
    = \(f : Text) ->
      \(attr : Text) ->
        Dep.Flake { flake = f, attr }

let nixpkgs
    : Text -> Dep
    = \(attr : Text) -> Dep.Flake { flake = "nixpkgs", attr }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- COMMON RULE FIELDS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let Common =
      { name : Text
      , visibility : Visibility
      , labels : List Text
      , coeffects : Coeffect.Coeffects
      }

let defaultCommon
    : Text -> Common
    = \(name : Text) ->
        { name
        , visibility = Visibility.Public
        , labels = [] : List Text
        , coeffects = Coeffect.pure
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- C++ RULES
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let CxxStandard =
      < Cxx11 | Cxx14 | Cxx17 | Cxx20 | Cxx23 >

let CxxLibrary =
      { common : Common
      , srcs : List Text
      , hdrs : List Text
      , deps : List Dep
      , includes : List Text
      , defines : List { name : Text, value : Optional Text }
      , copts : List Toolchain.Flag
      , standard : CxxStandard
      }

let cxx_library
    : Text -> List Text -> List Text -> CxxLibrary
    = \(name : Text) ->
      \(srcs : List Text) ->
      \(hdrs : List Text) ->
        { common = defaultCommon name
        , srcs
        , hdrs
        , deps = [] : List Dep
        , includes = [] : List Text
        , defines = [] : List { name : Text, value : Optional Text }
        , copts = [] : List Toolchain.Flag
        , standard = CxxStandard.Cxx23
        }

let CxxBinary =
      { common : Common
      , srcs : List Text
      , deps : List Dep
      , copts : List Toolchain.Flag
      , ldflags : List Text
      , standard : CxxStandard
      }

let cxx_binary
    : Text -> List Text -> CxxBinary
    = \(name : Text) ->
      \(srcs : List Text) ->
        { common = defaultCommon name
        , srcs
        , deps = [] : List Dep
        , copts = [] : List Toolchain.Flag
        , ldflags = [] : List Text
        , standard = CxxStandard.Cxx23
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- NVIDIA/CUDA RULES
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let NvBinary =
      { common : Common
      , srcs : List Text
      , deps : List Dep
      , archs : List Triple.Gpu    -- Target SM architectures
      , copts : List Toolchain.Flag
      , standard : CxxStandard
      }

let nv_binary
    : Text -> List Text -> List Triple.Gpu -> NvBinary
    = \(name : Text) ->
      \(srcs : List Text) ->
      \(archs : List Triple.Gpu) ->
        { common = defaultCommon name
        , srcs
        , deps = [] : List Dep
        , archs
        , copts = [] : List Toolchain.Flag
        , standard = CxxStandard.Cxx23
        }

-- Default: Blackwell targets
let nv_binary_blackwell
    : Text -> List Text -> NvBinary
    = \(name : Text) ->
      \(srcs : List Text) ->
        nv_binary name srcs [ Triple.Gpu.sm_100, Triple.Gpu.sm_120 ]

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- RUST RULES
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let RustEdition =
      < Edition2015 | Edition2018 | Edition2021 | Edition2024 >

let CrateType =
      < Bin | Lib | RLib | DyLib | CDyLib | StaticLib | ProcMacro >

let RustLibrary =
      { common : Common
      , srcs : List Text
      , deps : List Dep
      , edition : RustEdition
      , crate_type : CrateType
      , features : List Text
      , rustflags : List Toolchain.Flag
      , proc_macro : Bool
      }

let rust_library
    : Text -> List Text -> RustLibrary
    = \(name : Text) ->
      \(srcs : List Text) ->
        { common = defaultCommon name
        , srcs
        , deps = [] : List Dep
        , edition = RustEdition.Edition2024
        , crate_type = CrateType.RLib
        , features = [] : List Text
        , rustflags = [] : List Toolchain.Flag
        , proc_macro = False
        }

let RustBinary =
      { common : Common
      , srcs : List Text
      , deps : List Dep
      , edition : RustEdition
      , features : List Text
      , rustflags : List Toolchain.Flag
      }

let rust_binary
    : Text -> List Text -> RustBinary
    = \(name : Text) ->
      \(srcs : List Text) ->
        { common = defaultCommon name
        , srcs
        , deps = [] : List Dep
        , edition = RustEdition.Edition2024
        , features = [] : List Text
        , rustflags = [] : List Toolchain.Flag
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- HASKELL RULES
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let HaskellLibrary =
      { common : Common
      , srcs : List Text
      , deps : List Dep
      , packages : List Text
      , ghcOptions : List Text
      }

let haskell_library
    : Text -> List Text -> HaskellLibrary
    = \(name : Text) ->
      \(srcs : List Text) ->
        { common = defaultCommon name
        , srcs
        , deps = [] : List Dep
        , packages = [] : List Text
        , ghcOptions = [] : List Text
        }

let HaskellBinary =
      { common : Common
      , srcs : List Text
      , deps : List Dep
      , packages : List Text
      , ghcOptions : List Text
      , main : Text
      }

let haskell_binary
    : Text -> List Text -> HaskellBinary
    = \(name : Text) ->
      \(srcs : List Text) ->
        { common = defaultCommon name
        , srcs
        , deps = [] : List Dep
        , packages = [] : List Text
        , ghcOptions = [] : List Text
        , main = "Main"
        }

-- FFI binary (Haskell + C/C++)
let HaskellFFIBinary =
      { common : Common
      , hs_srcs : List Text
      , cxx_srcs : List Text
      , deps : List Dep
      , packages : List Text
      , extra_libs : List Text
      , ghcOptions : List Text
      }

let haskell_ffi_binary
    : Text -> List Text -> List Text -> HaskellFFIBinary
    = \(name : Text) ->
      \(hs_srcs : List Text) ->
      \(cxx_srcs : List Text) ->
        { common = defaultCommon name
        , hs_srcs
        , cxx_srcs
        , deps = [] : List Dep
        , packages = [] : List Text
        , extra_libs = [] : List Text
        , ghcOptions = [] : List Text
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- LEAN RULES
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let LeanLibrary =
      { common : Common
      , srcs : List Text
      , deps : List Dep
      , root : Text                 -- Root module name
      , extract_c : Bool            -- Extract to C
      }

let lean_library
    : Text -> List Text -> LeanLibrary
    = \(name : Text) ->
      \(srcs : List Text) ->
        { common = defaultCommon name
        , srcs
        , deps = [] : List Dep
        , root = name
        , extract_c = False
        }

let LeanBinary =
      { common : Common
      , srcs : List Text
      , deps : List Dep
      , root_module : Optional Text
      }

let lean_binary
    : Text -> List Text -> LeanBinary
    = \(name : Text) ->
      \(srcs : List Text) ->
        { common = defaultCommon name
        , srcs
        , deps = [] : List Dep
        , root_module = None Text
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- PURESCRIPT RULES
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let PureScriptApp =
      { common : Common
      , srcs : List Text            -- .purs files
      , ffi : List Text             -- .js FFI files
      , deps : List Dep
      , main : Text                 -- Main module
      , bundle : Bool               -- Bundle with esbuild
      }

let purescript_app
    : Text -> List Text -> PureScriptApp
    = \(name : Text) ->
      \(srcs : List Text) ->
        { common = defaultCommon name
        , srcs
        , ffi = [] : List Text
        , deps = [] : List Dep
        , main = "Main"
        , bundle = True
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- WASM RULES
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let WasmOptLevel =
      < O0 | O1 | O2 | O3 | Oz | Os >

let WasmFeature =
      < bulk_memory
      | simd128
      | threads
      | exception_handling
      | tail_call
      | multi_memory
      >

let WasmModule =
      { common : Common
      , src : Text                  -- Input (compiled C/Rust)
      , optimize : WasmOptLevel
      , features : List WasmFeature
      , exports : List Text
      }

let wasm_module
    : Text -> Text -> WasmModule
    = \(name : Text) ->
      \(src : Text) ->
        { common = defaultCommon name
        , src
        , optimize = WasmOptLevel.O3
        , features = [ WasmFeature.bulk_memory, WasmFeature.simd128 ]
        , exports = [] : List Text
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- NIX-INTEGRATED C++ (resolves flake deps at build time)
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let NixCxxBinary =
      { common : Common
      , srcs : List Text
      , nix_deps : List Text          -- Flake refs: "nixpkgs#zlib"
      , deps : List Dep
      , compiler_flags : List Text
      , linker_flags : List Text
      , standard : CxxStandard
      }

let nix_cxx_binary
    : Text -> List Text -> List Text -> NixCxxBinary
    = \(name : Text) ->
      \(srcs : List Text) ->
      \(nix_deps : List Text) ->
        { common = defaultCommon name
        , srcs
        , nix_deps
        , deps = [] : List Dep
        , compiler_flags = [] : List Text
        , linker_flags = [] : List Text
        , standard = CxxStandard.Cxx23
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- GENRULE (escape hatch)
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let Genrule =
      { common : Common
      , srcs : List Text
      , outs : List Text
      , cmd : Text
      }

let genrule
    : Text -> List Text -> List Text -> Text -> Genrule
    = \(name : Text) ->
      \(srcs : List Text) ->
      \(outs : List Text) ->
      \(cmd : Text) ->
        { common = defaultCommon name
        , srcs
        , outs
        , cmd
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- RULE UNION
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let Rule =
      < CxxLibrary : CxxLibrary
      | CxxBinary : CxxBinary
      | NvBinary : NvBinary
      | NixCxxBinary : NixCxxBinary
      | RustLibrary : RustLibrary
      | RustBinary : RustBinary
      | HaskellLibrary : HaskellLibrary
      | HaskellBinary : HaskellBinary
      | HaskellFFIBinary : HaskellFFIBinary
      | LeanLibrary : LeanLibrary
      | LeanBinary : LeanBinary
      | PureScriptApp : PureScriptApp
      | WasmModule : WasmModule
      | Genrule : Genrule
      >

in  { -- Types
      Visibility
    , Dep
    , Common
    , CxxStandard
    , CxxLibrary
    , CxxBinary
    , NvBinary
    , NixCxxBinary
    , RustEdition
    , CrateType
    , RustLibrary
    , RustBinary
    , HaskellLibrary
    , HaskellBinary
    , HaskellFFIBinary
    , LeanLibrary
    , LeanBinary
    , PureScriptApp
    , WasmOptLevel
    , WasmFeature
    , WasmModule
    , Genrule
    , Rule
    -- Constructors
    , defaultCommon
    , local
    , flake
    , nixpkgs
    , cxx_library
    , cxx_binary
    , nv_binary
    , nv_binary_blackwell
    , nix_cxx_binary
    , rust_library
    , rust_binary
    , haskell_library
    , haskell_binary
    , haskell_ffi_binary
    , lean_library
    , lean_binary
    , purescript_app
    , wasm_module
    , genrule
    }
