--| Toolchain definitions for Buck2
--|
--| These generate toolchain BUCK files from Dhall.

let T = ./Types.dhall

-- ══════════════════════════════════════════════════════════════════════════════
-- C++ Toolchain (LLVM)
-- ══════════════════════════════════════════════════════════════════════════════

let CxxToolchain =
      { name : Text
      , c_extra_flags : List Text
      , cxx_extra_flags : List Text
      , link_flags : List Text
      , link_style : Text
      , vis : T.Vis
      }

let cxxToolchain
    : Text -> CxxToolchain
    = \(name : Text) ->
        { name
        , c_extra_flags = [] : List Text
        , cxx_extra_flags = [] : List Text
        , link_flags = [] : List Text
        , link_style = "static"
        , vis = T.Vis.Public
        }

-- ══════════════════════════════════════════════════════════════════════════════
-- Haskell Toolchain
-- ══════════════════════════════════════════════════════════════════════════════

let HaskellToolchain =
      { name : Text
      , compiler_flags : List Text
      , vis : T.Vis
      }

let haskellToolchain
    : Text -> HaskellToolchain
    = \(name : Text) ->
        { name
        , compiler_flags = [ "-Wall", "-Werror", "-XGHC2024" ]
        , vis = T.Vis.Public
        }

-- ══════════════════════════════════════════════════════════════════════════════
-- Execution Platform
-- ══════════════════════════════════════════════════════════════════════════════

let ExecutionPlatform =
      { name : Text
      , local_enabled : Bool
      , remote_enabled : Bool
      , vis : T.Vis
      }

let executionPlatform
    : Text -> ExecutionPlatform
    = \(name : Text) ->
        { name
        , local_enabled = True
        , remote_enabled = False
        , vis = T.Vis.Public
        }

-- ══════════════════════════════════════════════════════════════════════════════
-- Python Bootstrap (required by Buck2)
-- ══════════════════════════════════════════════════════════════════════════════

let PythonBootstrap =
      { name : Text
      , vis : T.Vis
      }

let pythonBootstrap
    : Text -> PythonBootstrap
    = \(name : Text) ->
        { name
        , vis = T.Vis.Public
        }

-- ══════════════════════════════════════════════════════════════════════════════
-- Genrule Toolchain (required by Buck2)
-- ══════════════════════════════════════════════════════════════════════════════

let GenruleToolchain =
      { name : Text
      , vis : T.Vis
      }

let genruleToolchain
    : Text -> GenruleToolchain
    = \(name : Text) ->
        { name
        , vis = T.Vis.Public
        }

-- ══════════════════════════════════════════════════════════════════════════════
-- NVIDIA Toolchain
-- ══════════════════════════════════════════════════════════════════════════════

let NvToolchain =
      { name : Text
      , nv_archs : List Text
      , nvidia_sdk_path : Text
      , nvidia_sdk_include : Text
      , nvidia_sdk_lib : Text
      , vis : T.Vis
      }

let nvToolchain
    : Text -> NvToolchain
    = \(name : Text) ->
        { name
        , nv_archs = [ "sm_90", "sm_100", "sm_120" ]
        , nvidia_sdk_path = "/usr/local/cuda"
        , nvidia_sdk_include = "/usr/local/cuda/include"
        , nvidia_sdk_lib = "/usr/local/cuda/lib64"
        , vis = T.Vis.Public
        }

-- ══════════════════════════════════════════════════════════════════════════════
-- Rust Toolchain
-- ══════════════════════════════════════════════════════════════════════════════

let RustToolchain =
      { name : Text
      , default_edition : Text
      , rustc_flags : List Text
      , vis : T.Vis
      }

let rustToolchain
    : Text -> RustToolchain
    = \(name : Text) ->
        { name
        , default_edition = "2021"
        , rustc_flags = [ "-C", "opt-level=2", "-C", "debuginfo=2" ]
        , vis = T.Vis.Public
        }

-- ══════════════════════════════════════════════════════════════════════════════
-- Lean Toolchain
-- ══════════════════════════════════════════════════════════════════════════════

let LeanToolchain =
      { name : Text
      , vis : T.Vis
      }

let leanToolchain
    : Text -> LeanToolchain
    = \(name : Text) ->
        { name
        , vis = T.Vis.Public
        }

-- ══════════════════════════════════════════════════════════════════════════════
-- PureScript Toolchain
-- ══════════════════════════════════════════════════════════════════════════════

let PureScriptToolchain =
      { name : Text
      , vis : T.Vis
      }

let purescriptToolchain
    : Text -> PureScriptToolchain
    = \(name : Text) ->
        { name
        , vis = T.Vis.Public
        }

in  { CxxToolchain
    , cxxToolchain
    , HaskellToolchain
    , haskellToolchain
    , ExecutionPlatform
    , executionPlatform
    , PythonBootstrap
    , pythonBootstrap
    , GenruleToolchain
    , genruleToolchain
    , NvToolchain
    , nvToolchain
    , RustToolchain
    , rustToolchain
    , LeanToolchain
    , leanToolchain
    , PureScriptToolchain
    , purescriptToolchain
    }
