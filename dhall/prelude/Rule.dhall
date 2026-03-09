--| Rule union type
--|
--| All build rules as a single discriminated union.
--| This is what BUILD.dhall files return — sensenet parses this directly.

let T = ./Types.dhall
let C = ./Cxx.dhall
let R = ./Rust.dhall
let H = ./Haskell.dhall
let L = ./Lean.dhall
let N = ./Nv.dhall
let PS = ./PureScript.dhall
let G = ./Genrule.dhall
let NC = ./NixCxx.dhall
let RC = ./RustCrate.dhall

let Rule =
      < CxxBinary : C.Binary
      | CxxLibrary : C.Library
      | RustBinary : R.Binary
      | RustLibrary : R.Library
      | HaskellBinary : H.Binary
      | HaskellLibrary : H.Library
      | HaskellFFIBinary : H.FFIBinary
      | LeanBinary : L.Binary
      | LeanLibrary : L.Library
      | NvBinary : N.Binary
      | NvLibrary : N.Library
      | PureScriptApp : PS.App
      | PureScriptBinary : PS.Binary
      | PureScriptLibrary : PS.Library
      | Genrule : G.Genrule
      | NixCxxBinary : NC.NixBinary
      | CratesIo : RC.CratesIo
      | HttpArchive : RC.HttpArchive
      >

in  { Rule
    -- Constructors (for convenience)
    , cxxBinary = \(r : C.Binary) -> Rule.CxxBinary r
    , cxxLibrary = \(r : C.Library) -> Rule.CxxLibrary r
    , rustBinary = \(r : R.Binary) -> Rule.RustBinary r
    , rustLibrary = \(r : R.Library) -> Rule.RustLibrary r
    , haskellBinary = \(r : H.Binary) -> Rule.HaskellBinary r
    , haskellLibrary = \(r : H.Library) -> Rule.HaskellLibrary r
    , haskellFFIBinary = \(r : H.FFIBinary) -> Rule.HaskellFFIBinary r
    , leanBinary = \(r : L.Binary) -> Rule.LeanBinary r
    , leanLibrary = \(r : L.Library) -> Rule.LeanLibrary r
    , nvBinary = \(r : N.Binary) -> Rule.NvBinary r
    , nvLibrary = \(r : N.Library) -> Rule.NvLibrary r
    , purescriptApp = \(r : PS.App) -> Rule.PureScriptApp r
    , purescriptBinary = \(r : PS.Binary) -> Rule.PureScriptBinary r
    , purescriptLibrary = \(r : PS.Library) -> Rule.PureScriptLibrary r
    , genrule = \(r : G.Genrule) -> Rule.Genrule r
    , nixCxxBinary = \(r : NC.NixBinary) -> Rule.NixCxxBinary r
    , cratesIo = \(r : RC.CratesIo) -> Rule.CratesIo r
    , httpArchive = \(r : RC.HttpArchive) -> Rule.HttpArchive r
    }
