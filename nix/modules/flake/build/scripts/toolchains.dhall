-- toolchains.dhall
-- Generate .sensenet/toolchains.dhall with Nix store paths
--
-- This template is rendered by `nix develop` to create the runtime
-- toolchain configuration that sensenet reads directly.

let Schema = ../../../../dhall/Toolchains.dhall

-- Read paths from environment (set by Nix)
let cc = env:CC as Text
let cxx = env:CXX as Text
let ar = env:AR as Text
let ld = env:LD as Text
let clang_resource_dir = env:CLANG_RESOURCE_DIR as Text
let gcc_include = env:GCC_INCLUDE as Text
let gcc_include_arch = env:GCC_INCLUDE_ARCH as Text
let glibc_include = env:GLIBC_INCLUDE as Text
let gcc_lib = env:GCC_LIB as Text
let gcc_lib_base = env:GCC_LIB_BASE as Text
let glibc_lib = env:GLIBC_LIB as Text
let dynamic_linker = env:DYNAMIC_LINKER as Text

-- NVIDIA (optional - may not be present)
let nv_sdk_path = env:NVIDIA_SDK_PATH ? "" as Text
let nv_sdk_include = env:NVIDIA_SDK_INCLUDE ? "" as Text
let nv_sdk_lib = env:NVIDIA_SDK_LIB ? "" as Text
let nv_clang = env:NV_CLANG ? "" as Text
let nv_ptxas = env:PTXAS ? "" as Text
let nv_fatbinary = env:FATBINARY ? "" as Text
let nv_archs = env:NV_ARCHS ? "sm_90" as Text
let nv_mdspan = env:MDSPAN_INCLUDE ? "" as Text

-- Rust
let rustc = env:RUSTC as Text
let cargo = env:CARGO as Text

-- Haskell
let ghc = env:GHC as Text
let ghc_pkg = env:GHC_PKG as Text
let ghc_lib_dir = env:GHC_LIB_DIR as Text

-- Lean
let lean = env:LEAN as Text
let leanc = env:LEANC as Text
let lean_lib_dir = env:LEAN_LIB_DIR as Text
let lean_include_dir = env:LEAN_INCLUDE_DIR as Text

-- PureScript
let purs = env:PURS as Text
let spago = env:SPAGO as Text
let node = env:NODE as Text
let esbuild = env:ESBUILD as Text

-- Build the config
let cxxToolchain : Schema.Cxx =
      { cc
      , cxx
      , ar
      , ld
      , clang_resource_dir
      , gcc_include
      , gcc_include_arch
      , glibc_include
      , gcc_lib
      , gcc_lib_base
      , glibc_lib
      , dynamic_linker
      }

let nvToolchain : Optional Schema.Nv =
      if    nv_sdk_path == ""
      then  None Schema.Nv
      else  Some
              { sdk_path = nv_sdk_path
              , sdk_include = nv_sdk_include
              , sdk_lib = nv_sdk_lib
              , clang = nv_clang
              , ptxas = nv_ptxas
              , fatbinary = nv_fatbinary
              , archs =
                  -- Split comma-separated archs into list
                  -- For now just use a single-element list; proper split would need prelude
                  [ nv_archs ]
              , mdspan_include =
                  if nv_mdspan == "" then None Text else Some nv_mdspan
              }

let rustToolchain : Schema.Rust =
      { rustc
      , cargo
      , default_edition = "2021"
      }

let haskellToolchain : Schema.Haskell =
      { ghc
      , ghc_pkg
      , ghc_lib_dir
      }

let leanToolchain : Schema.Lean =
      { lean
      , leanc
      , lib_dir = lean_lib_dir
      , include_dir = lean_include_dir
      }

let purescriptToolchain : Schema.PureScript =
      { purs
      , spago
      , node
      , esbuild
      }

in  { cxx = cxxToolchain
    , nv = nvToolchain
    , rust = rustToolchain
    , haskell = haskellToolchain
    , lean = leanToolchain
    , purescript = purescriptToolchain
    } : Schema.Toolchains
