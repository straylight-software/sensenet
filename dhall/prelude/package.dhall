--| Aleph Prelude

let T = ./Types.dhall
let C = ./Cxx.dhall
let R = ./Rust.dhall
let H = ./Haskell.dhall
let L = ./Lean.dhall
let N = ./Nv.dhall
let PS = ./PureScript.dhall
let TC = ./Toolchain.dhall
let G = ./Genrule.dhall
let RC = ./RustCrate.dhall
let NC = ./NixCxx.dhall
let Ru = ./Rule.dhall

in  { -- Rule union (for BUILD.dhall files)
      Rule = Ru.Rule
    , rule = Ru
    -- Types
    , Dep = T.Dep
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
    -- Haskell rules
    , StanConfig = H.StanConfig
    , HaskellBinary = H.Binary
    , haskellBinary = H.binary
    , HaskellLibrary = H.Library
    , haskellLibrary = H.library
    , HaskellFFIBinary = H.FFIBinary
    , haskellFFIBinary = H.ffiBinary
    -- Lean rules
    , LeanBinary = L.Binary
    , leanBinary = L.binary
    , LeanLibrary = L.Library
    , leanLibrary = L.library
    -- NVIDIA rules
    , NvBinary = N.Binary
    , nvBinary = N.binary
    , NvLibrary = N.Library
    , nvLibrary = N.library
    -- PureScript rules
    , PureScriptApp = PS.App
    , purescriptApp = PS.app
    , PureScriptBinary = PS.Binary
    , purescriptBinary = PS.binary
    , PureScriptLibrary = PS.Library
    , purescriptLibrary = PS.library
    , SrcSpec = PS.SrcSpec
    -- Toolchains
    , CxxToolchain = TC.CxxToolchain
    , cxxToolchain = TC.cxxToolchain
    , HaskellToolchain = TC.HaskellToolchain
    , haskellToolchain = TC.haskellToolchain
    , ExecutionPlatform = TC.ExecutionPlatform
    , executionPlatform = TC.executionPlatform
    , PythonBootstrap = TC.PythonBootstrap
    , pythonBootstrap = TC.pythonBootstrap
    , GenruleToolchain = TC.GenruleToolchain
    , genruleToolchain = TC.genruleToolchain
    , NvToolchain = TC.NvToolchain
    , nvToolchain = TC.nvToolchain
    , RustToolchain = TC.RustToolchain
    , rustToolchain = TC.rustToolchain
    , LeanToolchain = TC.LeanToolchain
    , leanToolchain = TC.leanToolchain
    , PureScriptToolchain = TC.PureScriptToolchain
    , purescriptToolchain = TC.purescriptToolchain
    -- Genrule
    , Genrule = G.Genrule
    , genrule = G.genrule
    -- Rust crates
    , CratesIo = RC.CratesIo
    , cratesIo = RC.cratesIo
    , HttpArchive = RC.HttpArchive
    , httpArchive = RC.httpArchive
    -- Nix C++
    , NixCxxBinary = NC.NixBinary
    , nixCxxBinary = NC.nixBinary
    -- Backward compat (short names for common case)
    , Binary = C.Binary
    , binary = C.binary
    , Library = C.Library
    , library = C.library
    }
