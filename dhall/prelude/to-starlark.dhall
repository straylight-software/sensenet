--| Dhall -> Starlark

let P = ./Prelude.dhall
let T = ./Types.dhall
let C = ./Cxx.dhall
let R = ./Rust.dhall

let q = \(t : Text) -> "\"${t}\""

let list = \(xs : List Text) ->
    "[" ++ P.Text.concatSep ", " (P.List.map Text Text q xs) ++ "]"

let flakes
    : List T.Dep -> List Text
    = \(ds : List T.Dep) ->
        P.List.concatMap T.Dep Text
          (\(d : T.Dep) -> merge { Local = \(_ : Text) -> [] : List Text
                                 , Flake = \(r : Text) -> [r] } d) ds

let locals
    : List T.Dep -> List Text
    = \(ds : List T.Dep) ->
        P.List.concatMap T.Dep Text
          (\(d : T.Dep) -> merge { Local = \(t : Text) -> [t]
                                 , Flake = \(_ : Text) -> [] : List Text } d) ds

let cxxStd = \(s : T.CxxStd) -> merge
    { Cxx11 = "-std=c++11", Cxx14 = "-std=c++14", Cxx17 = "-std=c++17"
    , Cxx20 = "-std=c++20", Cxx23 = "-std=c++23" } s

let rustEdition = \(e : R.Edition) -> merge
    { E2015 = "2015", E2018 = "2018", E2021 = "2021", E2024 = "2024" } e

let vis = \(v : T.Vis) -> merge { Public = "[\"PUBLIC\"]", Private = "[]" } v

let Flags = { compiler : List Text, linker : List Text }

let cxxBinary
    : C.Binary -> Flags -> Text
    = \(b : C.Binary) -> \(f : Flags) ->
        let cf = [cxxStd b.std] # b.cflags # f.compiler
        let lf = b.ldflags # f.linker
        in ''
        cxx_binary(
            name = ${q b.name},
            srcs = ${list b.srcs},
            deps = ${list (locals b.deps)},
            compiler_flags = ${list cf},
            linker_flags = ${list lf},
            visibility = ${vis b.vis},
        )
        ''

let rustBinary
    : R.Binary -> Text
    = \(b : R.Binary) ->
        ''
        rust_binary(
            name = ${q b.name},
            srcs = ${list b.srcs},
            deps = ${list (locals b.deps)},
            edition = ${q (rustEdition b.edition)},
            visibility = ${vis b.vis},
        )
        ''

let rustLibrary
    : R.Library -> Text
    = \(lib : R.Library) ->
        let crateName = merge { Some = \(n : Text) -> "    crate_name = ${q n},\n"
                              , None = "" } lib.crate_name
        let procMacro = if lib.proc_macro then "    proc_macro = True,\n" else ""
        let features = if P.List.null Text lib.features
                       then ""
                       else "    features = ${list lib.features},\n"
        in ''
        rust_library(
            name = ${q lib.name},
            srcs = ${list lib.srcs},
            deps = ${list (locals lib.deps)},
            edition = ${q (rustEdition lib.edition)},
        ${crateName}${procMacro}${features}    visibility = ${vis lib.vis},
        )
        ''

let cxxDeps = \(b : C.Binary) -> P.Text.concatSep "\n" (flakes b.deps)
let rustBinaryDeps = \(b : R.Binary) -> P.Text.concatSep "\n" (flakes b.deps)
let rustLibraryDeps = \(lib : R.Library) -> P.Text.concatSep "\n" (flakes lib.deps)

-- Backward compat aliases
let std = cxxStd
let binary = cxxBinary
let deps = cxxDeps

in  { q, list, flakes, locals
    , cxxStd, rustEdition, vis, Flags
    , cxxBinary, rustBinary, rustLibrary
    , cxxDeps, rustBinaryDeps, rustLibraryDeps
    -- backward compat
    , std, binary, deps
    }
